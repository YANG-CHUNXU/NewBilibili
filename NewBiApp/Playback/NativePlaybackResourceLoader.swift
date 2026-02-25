import Foundation
import AVFoundation
import UniformTypeIdentifiers
@_spi(PlaybackProxy) import NewBiCore

final class NativePlaybackResourceLoader: NSObject {
    static let shared = NativePlaybackResourceLoader()

    private static let proxyScheme = "newbi-proxy"
    private static let sessionTimeout: TimeInterval = 10 * 60
    private static let streamChunkSize = 64 * 1024
    private static let rangeProbeTimeout: TimeInterval = 4

    private let urlSession: URLSession
    private let store: ProxySessionStore
    private let delegateQueue = DispatchQueue(label: "com.newbi.playback.proxy", qos: .userInitiated)

    private let inflightLock = NSLock()
    private var inflightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: configuration)
        self.store = ProxySessionStore(timeout: Self.sessionTimeout)
        super.init()
    }

    func makeAsset(for stream: PlayableStream) async throws -> AVURLAsset {
        let sessionID = await store.create(stream: stream)

        let entryPath: String
        switch stream.transport {
        case .progressive:
            entryPath = "/progressive"
        case .progressivePlaylist:
            entryPath = "/progressive.m3u8"
        case .dash:
            entryPath = "/master.m3u8"
        }

        guard let url = proxyURL(sessionID: sessionID, path: entryPath) else {
            throw BiliClientError.playbackProxyFailed("生成本地代理 URL 失败")
        }

        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    func release(asset: AVAsset?) {
        guard let urlAsset = asset as? AVURLAsset,
              let sessionID = sessionID(from: urlAsset.url)
        else {
            return
        }

        Task {
            await store.remove(sessionID)
        }
    }

    private func proxyURL(sessionID: UUID, path: String) -> URL? {
        NativePlaybackProxyUtilities.proxyURL(scheme: Self.proxyScheme, sessionID: sessionID, path: path)
    }

    private func sessionID(from url: URL) -> UUID? {
        guard url.scheme == Self.proxyScheme,
              let host = url.host
        else {
            return nil
        }
        return UUID(uuidString: host)
    }

    private func route(from url: URL) -> ProxyRoute? {
        guard let sessionID = sessionID(from: url) else {
            return nil
        }

        if url.path == "/progressive.m3u8" {
            return ProxyRoute(sessionID: sessionID, kind: .progressivePlaylist)
        }
        if let index = progressiveSegmentIndex(fromPath: url.path) {
            return ProxyRoute(sessionID: sessionID, kind: .progressivePlaylistSegment(index: index))
        }

        switch url.path {
        case "/master.m3u8":
            return ProxyRoute(sessionID: sessionID, kind: .masterPlaylist)
        case "/video.m3u8":
            return ProxyRoute(sessionID: sessionID, kind: .videoPlaylist)
        case "/audio.m3u8":
            return ProxyRoute(sessionID: sessionID, kind: .audioPlaylist)
        case "/progressive":
            return ProxyRoute(sessionID: sessionID, kind: .progressiveSegment)
        case "/video.segment":
            return ProxyRoute(sessionID: sessionID, kind: .videoSegment)
        case "/audio.segment":
            return ProxyRoute(sessionID: sessionID, kind: .audioSegment)
        default:
            return nil
        }
    }

    private func progressiveSegmentPath(index: Int) -> String {
        "/progressive/\(index).segment"
    }

    private func progressiveSegmentIndex(fromPath path: String) -> Int? {
        guard path.hasPrefix("/progressive/"),
              path.hasSuffix(".segment")
        else {
            return nil
        }

        let prefixCount = "/progressive/".count
        let suffixCount = ".segment".count
        let start = path.index(path.startIndex, offsetBy: prefixCount)
        let end = path.index(path.endIndex, offsetBy: -suffixCount)
        guard start < end else {
            return nil
        }

        return Int(path[start..<end])
    }

    private func register(task: Task<Void, Never>, for request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        inflightLock.lock()
        inflightTasks[key] = task
        inflightLock.unlock()
    }

    private func removeTask(for request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        inflightLock.lock()
        inflightTasks.removeValue(forKey: key)
        inflightLock.unlock()
    }

    private func cancelTask(for request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        inflightLock.lock()
        let task = inflightTasks.removeValue(forKey: key)
        inflightLock.unlock()
        task?.cancel()
    }

    private func handle(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        guard let url = loadingRequest.request.url,
              let route = route(from: url)
        else {
            loadingRequest.finishLoading(with: BiliClientError.playbackProxyFailed("代理路由无效"))
            return
        }

        guard let session = await store.get(route.sessionID) else {
            loadingRequest.finishLoading(with: BiliClientError.playbackProxyFailed("播放会话不存在或已过期"))
            return
        }

        do {
            switch route.kind {
            case .masterPlaylist:
                let text = try makeMasterPlaylist(sessionID: route.sessionID, stream: session.stream)
                try respondText(text, contentType: UTType.m3uPlaylist.identifier, to: loadingRequest)
            case .videoPlaylist:
                let text = makeMediaPlaylist(sessionID: route.sessionID, segmentPath: "/video.segment")
                try respondText(text, contentType: UTType.m3uPlaylist.identifier, to: loadingRequest)
            case .audioPlaylist:
                let text = makeMediaPlaylist(sessionID: route.sessionID, segmentPath: "/audio.segment")
                try respondText(text, contentType: UTType.m3uPlaylist.identifier, to: loadingRequest)
            case .progressivePlaylist:
                let text = try makeProgressivePlaylist(sessionID: route.sessionID, stream: session.stream)
                try respondText(text, contentType: UTType.m3uPlaylist.identifier, to: loadingRequest)
            case .progressiveSegment:
                guard case .progressive(let remoteURL, let fallbackURLs) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 progressive 流")
                }
                try await proxyRemoteWithFallback(
                    sessionID: route.sessionID,
                    lane: .progressive,
                    candidates: [remoteURL] + fallbackURLs,
                    headers: session.stream.headers,
                    to: loadingRequest
                )
            case .progressivePlaylistSegment(let index):
                guard case .progressivePlaylist(let segments) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 progressive playlist 流")
                }
                guard segments.indices.contains(index) else {
                    throw BiliClientError.playbackProxyFailed("分段索引越界: \(index)")
                }
                let segment = segments[index]
                try await proxyRemoteWithFallback(
                    sessionID: route.sessionID,
                    lane: .progressive,
                    candidates: [segment.url] + segment.fallbackURLs,
                    headers: session.stream.headers,
                    to: loadingRequest
                )
            case .videoSegment:
                guard case .dash(let videoURL, _, let videoFallbackURLs, _) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 DASH 流")
                }
                try await proxyRemoteWithFallback(
                    sessionID: route.sessionID,
                    lane: .video,
                    candidates: [videoURL] + videoFallbackURLs,
                    headers: session.stream.headers,
                    to: loadingRequest
                )
            case .audioSegment:
                guard case .dash(_, let audioURL, _, let audioFallbackURLs) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 DASH 流")
                }
                guard let audioURL else {
                    throw BiliClientError.unsupportedDashStream("DASH 音频轨缺失")
                }
                try await proxyRemoteWithFallback(
                    sessionID: route.sessionID,
                    lane: .audio,
                    candidates: [audioURL] + audioFallbackURLs,
                    headers: session.stream.headers,
                    to: loadingRequest
                )
            }
        } catch {
            if isCancellationError(error) {
                return
            }
            loadingRequest.finishLoading(with: error)
        }
    }

    private func makeMasterPlaylist(sessionID: UUID, stream: PlayableStream) throws -> String {
        switch stream.transport {
        case .progressive, .progressivePlaylist:
            throw BiliClientError.playbackProxyFailed("progressive 不需要 master 清单")
        case .dash(_, let audioURL, _, _):
            guard let playlist = NativePlaybackProxyUtilities.makeMasterPlaylist(
                scheme: Self.proxyScheme,
                sessionID: sessionID,
                hasAudio: audioURL != nil
            ) else {
                throw BiliClientError.playbackProxyFailed("生成 master 清单失败")
            }
            return playlist
        }
    }

    private func makeMediaPlaylist(sessionID: UUID, segmentPath: String) -> String {
        NativePlaybackProxyUtilities.makeMediaPlaylist(
            scheme: Self.proxyScheme,
            sessionID: sessionID,
            segmentPath: segmentPath
        ) ?? "#EXTM3U\n#EXT-X-ENDLIST"
    }

    private func makeProgressivePlaylist(sessionID: UUID, stream: PlayableStream) throws -> String {
        guard case .progressivePlaylist(let segments) = stream.transport else {
            throw BiliClientError.playbackProxyFailed("会话并非 progressive playlist 流")
        }
        guard !segments.isEmpty else {
            throw BiliClientError.playbackProxyFailed("progressive playlist 为空")
        }

        let playlistSegments = segments.enumerated().map { index, segment in
            NativePlaybackProxyUtilities.MediaPlaylistSegment(
                segmentPath: progressiveSegmentPath(index: index),
                durationSeconds: segment.durationSeconds
            )
        }
        guard let playlist = NativePlaybackProxyUtilities.makeMediaPlaylist(
            scheme: Self.proxyScheme,
            sessionID: sessionID,
            segments: playlistSegments
        ) else {
            throw BiliClientError.playbackProxyFailed("生成 progressive playlist 失败")
        }

        return playlist
    }

    private func respondText(_ text: String, contentType: String, to loadingRequest: AVAssetResourceLoadingRequest) throws {
        guard let data = text.data(using: .utf8) else {
            throw BiliClientError.playbackProxyFailed("清单编码失败")
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }

        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    private func proxyRemoteWithFallback(
        sessionID: UUID,
        lane: ProxyRemoteLane,
        candidates: [URL],
        headers: PlaybackHeaders,
        to loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        let orderedCandidates = await store.orderedCandidates(candidates, for: lane, in: sessionID)
        guard !orderedCandidates.isEmpty else {
            throw BiliClientError.playbackProxyFailed("缺少可用分段地址")
        }

        if let requestedRange = RequestedRange(dataRequest: loadingRequest.dataRequest) {
            var probeResults: [URL: NativePlaybackProxyUtilities.RangeProbeResult] = [:]
            var lastError: Error?

            for remoteURL in orderedCandidates {
                do {
                    let probeResult = try await probeRangeCapability(
                        remoteURL,
                        requestedRange: requestedRange,
                        headers: headers
                    )
                    probeResults[remoteURL] = probeResult
                } catch {
                    if isCancellationError(error) {
                        throw error
                    }
                    probeResults[remoteURL] = .failed
                    lastError = error
                }
            }

            guard let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
                orderedCandidates: orderedCandidates,
                probeResults: probeResults
            ) else {
                throw lastError ?? BiliClientError.playbackProxyFailed("Range 探测未找到可用分段地址")
            }

            let outcome = try await proxyRemote(selection.url, headers: headers, to: loadingRequest)
            if selection.shouldMarkPreferredCandidate, outcome.shouldMarkPreferredCandidate {
                await store.markPreferredCandidate(selection.url, for: lane, in: sessionID)
            }
            return
        }

        var lastError: Error?
        for remoteURL in orderedCandidates {
            do {
                let outcome = try await proxyRemote(remoteURL, headers: headers, to: loadingRequest)
                if outcome.shouldMarkPreferredCandidate {
                    await store.markPreferredCandidate(remoteURL, for: lane, in: sessionID)
                }
                return
            } catch {
                if isCancellationError(error) {
                    throw error
                }
                lastError = error
            }
        }

        throw lastError ?? BiliClientError.playbackProxyFailed("分段代理失败")
    }

    private func probeRangeCapability(
        _ remoteURL: URL,
        requestedRange: RequestedRange,
        headers: PlaybackHeaders
    ) async throws -> NativePlaybackProxyUtilities.RangeProbeResult {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.rangeProbeTimeout
        let forwardHeaders = NativePlaybackProxyUtilities.buildForwardHeaders(
            base: headers,
            range: requestedRange.probeHeaderValue
        )
        for (key, value) in forwardHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            throw BiliClientError.playbackProxyFailed(error.localizedDescription)
        }
        defer {
            bytes.task.cancel()
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed
        }

        switch http.statusCode {
        case 206:
            guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsedRange = ParsedContentRange.parse(contentRange),
                  parsedRange.start == requestedRange.start
            else {
                return .failed
            }
            return .supports206
        case 200:
            return .fallback200
        default:
            return .failed
        }
    }

    private func proxyRemote(
        _ remoteURL: URL,
        headers: PlaybackHeaders,
        to loadingRequest: AVAssetResourceLoadingRequest
    ) async throws -> ProxyRemoteOutcome {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 20
        let requestedRange = RequestedRange(dataRequest: loadingRequest.dataRequest)
        let rangeValue = requestedRange?.headerValue
        let forwardHeaders = NativePlaybackProxyUtilities.buildForwardHeaders(base: headers, range: rangeValue)
        for (key, value) in forwardHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            throw BiliClientError.playbackProxyFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BiliClientError.playbackProxyFailed("远端响应无效")
        }
        guard (200...299).contains(http.statusCode) else {
            throw BiliClientError.networkFailed("HTTP \(http.statusCode)")
        }

        let rangeDisposition = try validateRangeResponse(http: http, requestedRange: requestedRange)

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = resolvedContentType(remoteURL: remoteURL, mimeType: http.mimeType)
            if let contentLength = resolvedContentLength(http: http, parsedContentRange: rangeDisposition.parsedContentRange) {
                info.contentLength = contentLength
            }
            info.isByteRangeAccessSupported = rangeDisposition.isByteRangeAccessSupported
        }

        var buffer = Data()
        buffer.reserveCapacity(Self.streamChunkSize)
        var bytesToDiscard = rangeDisposition.bytesToDiscard
        var remainingBytesToRespond = rangeDisposition.maxBytesToRespond

        do {
            for try await byte in bytes {
                try Task.checkCancellation()

                if bytesToDiscard > 0 {
                    bytesToDiscard -= 1
                    continue
                }

                if let remaining = remainingBytesToRespond, remaining <= 0 {
                    break
                }

                buffer.append(byte)
                if let remaining = remainingBytesToRespond {
                    remainingBytesToRespond = remaining - 1
                }
                if buffer.count >= Self.streamChunkSize {
                    loadingRequest.dataRequest?.respond(with: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }

                if remainingBytesToRespond == 0 {
                    break
                }
            }
        } catch {
            if isCancellationError(error) {
                throw CancellationError()
            }
            throw BiliClientError.playbackProxyFailed(error.localizedDescription)
        }

        if bytesToDiscard > 0 {
            throw BiliClientError.playbackProxyFailed("Range 起点超出远端资源长度")
        }

        if !buffer.isEmpty {
            loadingRequest.dataRequest?.respond(with: buffer)
        }

        loadingRequest.finishLoading()
        return ProxyRemoteOutcome(shouldMarkPreferredCandidate: rangeDisposition.shouldMarkPreferredCandidate)
    }

    private func resolvedContentType(remoteURL: URL, mimeType: String?) -> String {
        if let mimeType {
            let lower = mimeType.lowercased()
            if lower.contains("mpegurl") || lower.contains("m3u8") {
                return UTType.m3uPlaylist.identifier
            }
            if lower.contains("mp4") || lower.contains("m4s") {
                return UTType.mpeg4Movie.identifier
            }
        }

        switch remoteURL.pathExtension.lowercased() {
        case "m3u8":
            return UTType.m3uPlaylist.identifier
        case "mp4", "m4s":
            return UTType.mpeg4Movie.identifier
        default:
            return UTType.data.identifier
        }
    }

    private func resolvedContentLength(
        http: HTTPURLResponse,
        parsedContentRange: ParsedContentRange?
    ) -> Int64? {
        if let totalLength = parsedContentRange?.totalLength {
            return totalLength
        }

        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int64(contentLength)
        {
            return contentLength
        }

        let expected = http.expectedContentLength
        return expected >= 0 ? expected : nil
    }

    private func validateRangeResponse(
        http: HTTPURLResponse,
        requestedRange: RequestedRange?
    ) throws -> RangeResponseDisposition {
        let parsedContentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(ParsedContentRange.parse)

        guard let requestedRange else {
            return RangeResponseDisposition(
                parsedContentRange: parsedContentRange,
                bytesToDiscard: 0,
                maxBytesToRespond: nil,
                isByteRangeAccessSupported: true,
                shouldMarkPreferredCandidate: true
            )
        }

        switch http.statusCode {
        case 206:
            guard let parsedContentRange else {
                throw BiliClientError.playbackProxyFailed("Range 响应缺少或无效 Content-Range")
            }

            guard parsedContentRange.start == requestedRange.start else {
                throw BiliClientError.playbackProxyFailed("Range 响应起点与请求不一致")
            }

            if let requestedEnd = requestedRange.end,
               parsedContentRange.end > requestedEnd
            {
                throw BiliClientError.playbackProxyFailed("Range 响应超出请求范围")
            }

            return RangeResponseDisposition(
                parsedContentRange: parsedContentRange,
                bytesToDiscard: 0,
                maxBytesToRespond: nil,
                isByteRangeAccessSupported: true,
                shouldMarkPreferredCandidate: true
            )
        case 200:
            return RangeResponseDisposition(
                parsedContentRange: parsedContentRange,
                bytesToDiscard: requestedRange.start,
                maxBytesToRespond: requestedRange.length,
                isByteRangeAccessSupported: false,
                shouldMarkPreferredCandidate: false
            )
        default:
            throw BiliClientError.playbackProxyFailed("Range 请求返回不支持的状态码: \(http.statusCode)")
        }
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError,
           urlError.code == .cancelled
        {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
    }
}

extension NativePlaybackResourceLoader: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await handle(loadingRequest)
            removeTask(for: loadingRequest)
        }
        register(task: task, for: loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        cancelTask(for: loadingRequest)
    }
}

private struct ProxyRoute {
    enum Kind {
        case masterPlaylist
        case videoPlaylist
        case audioPlaylist
        case progressivePlaylist
        case progressiveSegment
        case progressivePlaylistSegment(index: Int)
        case videoSegment
        case audioSegment
    }

    let sessionID: UUID
    let kind: Kind
}

private enum ProxyRemoteLane: String, Hashable, Sendable {
    case progressive
    case video
    case audio
}

private struct ProxyRemoteOutcome {
    let shouldMarkPreferredCandidate: Bool
}

private struct RangeResponseDisposition {
    let parsedContentRange: ParsedContentRange?
    let bytesToDiscard: Int64
    let maxBytesToRespond: Int64?
    let isByteRangeAccessSupported: Bool
    let shouldMarkPreferredCandidate: Bool
}

private struct RequestedRange {
    let start: Int64
    let end: Int64?

    init?(dataRequest: AVAssetResourceLoadingDataRequest?) {
        guard let dataRequest else {
            return nil
        }

        let startOffset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength
        if startOffset == 0, requestedLength <= 0 {
            return nil
        }

        guard startOffset >= 0 else {
            return nil
        }

        self.start = startOffset

        if requestedLength > 0 {
            let length = Int64(requestedLength)
            guard startOffset <= Int64.max - length + 1 else {
                return nil
            }
            self.end = startOffset + length - 1
        } else {
            self.end = nil
        }
    }

    var headerValue: String {
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    var probeHeaderValue: String {
        "bytes=\(start)-\(start)"
    }

    var length: Int64? {
        guard let end else {
            return nil
        }
        return end - start + 1
    }
}

private struct ParsedContentRange {
    let start: Int64
    let end: Int64
    let totalLength: Int64?

    static func parse(_ rawValue: String) -> ParsedContentRange? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes ") else {
            return nil
        }

        let rangeAndTotal = value.dropFirst(6)
        let parts = rangeAndTotal.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        let rangePart = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let totalPart = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard rangePart != "*" else {
            return nil
        }

        let bounds = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start
        else {
            return nil
        }

        let totalLength: Int64?
        if totalPart == "*" {
            totalLength = nil
        } else {
            guard let parsedTotal = Int64(totalPart),
                  parsedTotal > 0,
                  end < parsedTotal
            else {
                return nil
            }
            totalLength = parsedTotal
        }

        return ParsedContentRange(start: start, end: end, totalLength: totalLength)
    }
}

private actor ProxySessionStore {
    struct SessionEntry {
        let stream: PlayableStream
        let createdAt: Date
        var lastAccessedAt: Date
        var preferredRemoteByLane: [ProxyRemoteLane: String]
    }

    private var sessions: [UUID: SessionEntry] = [:]
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func create(stream: PlayableStream) -> UUID {
        purgeExpired()
        let id = UUID()
        let now = Date()
        sessions[id] = SessionEntry(
            stream: stream,
            createdAt: now,
            lastAccessedAt: now,
            preferredRemoteByLane: [:]
        )
        return id
    }

    func get(_ id: UUID) -> SessionEntry? {
        purgeExpired()
        guard var entry = sessions[id] else {
            return nil
        }
        entry.lastAccessedAt = Date()
        sessions[id] = entry
        return entry
    }

    func remove(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func orderedCandidates(_ candidates: [URL], for lane: ProxyRemoteLane, in sessionID: UUID) -> [URL] {
        purgeExpired()

        let uniqueCandidates = NativePlaybackProxyUtilities.deduplicatedCandidateURLs(candidates)
        guard !uniqueCandidates.isEmpty else {
            return []
        }

        guard var entry = sessions[sessionID] else {
            return uniqueCandidates
        }

        entry.lastAccessedAt = Date()
        sessions[sessionID] = entry

        let preferred = entry.preferredRemoteByLane[lane].flatMap(URL.init(string:))
        return NativePlaybackProxyUtilities.prioritizedCandidateURLs(uniqueCandidates, preferred: preferred)
    }

    func markPreferredCandidate(_ candidate: URL, for lane: ProxyRemoteLane, in sessionID: UUID) {
        purgeExpired()
        guard var entry = sessions[sessionID] else {
            return
        }

        entry.lastAccessedAt = Date()
        entry.preferredRemoteByLane[lane] = candidate.absoluteString
        sessions[sessionID] = entry
    }

    private func purgeExpired(now: Date = Date()) {
        sessions = sessions.filter { _, entry in
            now.timeIntervalSince(entry.lastAccessedAt) < timeout
        }
    }
}
