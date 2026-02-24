import Foundation
import AVFoundation
import UniformTypeIdentifiers
import NewBiCore

final class NativePlaybackResourceLoader: NSObject {
    static let shared = NativePlaybackResourceLoader()

    private static let proxyScheme = "newbi-proxy"
    private static let sessionTimeout: TimeInterval = 10 * 60

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
            case .progressiveSegment:
                guard case .progressive(let remoteURL) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 progressive 流")
                }
                try await proxyRemote(remoteURL, headers: session.stream.headers, to: loadingRequest)
            case .videoSegment:
                guard case .dash(let videoURL, _) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 DASH 流")
                }
                try await proxyRemote(videoURL, headers: session.stream.headers, to: loadingRequest)
            case .audioSegment:
                guard case .dash(_, let audioURL) = session.stream.transport else {
                    throw BiliClientError.unsupportedDashStream("会话并非 DASH 流")
                }
                guard let audioURL else {
                    throw BiliClientError.unsupportedDashStream("DASH 音频轨缺失")
                }
                try await proxyRemote(audioURL, headers: session.stream.headers, to: loadingRequest)
            }
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func makeMasterPlaylist(sessionID: UUID, stream: PlayableStream) throws -> String {
        switch stream.transport {
        case .progressive:
            throw BiliClientError.playbackProxyFailed("progressive 不需要 master 清单")
        case .dash(_, let audioURL):
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

    private func proxyRemote(
        _ remoteURL: URL,
        headers: PlaybackHeaders,
        to loadingRequest: AVAssetResourceLoadingRequest
    ) async throws {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 20
        let rangeValue = makeRangeHeader(for: loadingRequest.dataRequest)
        let forwardHeaders = NativePlaybackProxyUtilities.buildForwardHeaders(base: headers, range: rangeValue)
        for (key, value) in forwardHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw BiliClientError.playbackProxyFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BiliClientError.playbackProxyFailed("远端响应无效")
        }
        guard (200...299).contains(http.statusCode) else {
            throw BiliClientError.networkFailed("HTTP \(http.statusCode)")
        }

        let payload = adjustedPayload(data: data, httpStatusCode: http.statusCode, dataRequest: loadingRequest.dataRequest)

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = resolvedContentType(remoteURL: remoteURL, mimeType: http.mimeType)
            info.contentLength = resolvedContentLength(http: http, dataCount: data.count, dataRequest: loadingRequest.dataRequest)
            info.isByteRangeAccessSupported = true
        }

        loadingRequest.dataRequest?.respond(with: payload)
        loadingRequest.finishLoading()
    }

    private func makeRangeHeader(for dataRequest: AVAssetResourceLoadingDataRequest?) -> String? {
        guard let dataRequest else {
            return nil
        }

        return NativePlaybackProxyUtilities.makeRangeHeader(
            requestedOffset: dataRequest.requestedOffset,
            currentOffset: dataRequest.currentOffset,
            requestedLength: dataRequest.requestedLength
        )
    }

    private func adjustedPayload(
        data: Data,
        httpStatusCode: Int,
        dataRequest: AVAssetResourceLoadingDataRequest?
    ) -> Data {
        guard httpStatusCode == 200, let dataRequest else {
            return data
        }

        let startOffset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        guard startOffset >= 0 else {
            return data
        }

        let start = min(max(Int(startOffset), 0), data.count)
        guard start < data.count else {
            return Data()
        }

        let requestedLength = dataRequest.requestedLength
        if requestedLength <= 0 {
            return data.subdata(in: start..<data.count)
        }

        let end = min(start + requestedLength, data.count)
        return data.subdata(in: start..<end)
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
        dataCount: Int,
        dataRequest: AVAssetResourceLoadingDataRequest?
    ) -> Int64 {
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRange.lastIndex(of: "/")
        {
            let totalString = contentRange[contentRange.index(after: slashIndex)...]
            if let total = Int64(totalString) {
                return total
            }
        }

        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int64(contentLength)
        {
            if http.statusCode == 206,
               let dataRequest
            {
                return dataRequest.requestedOffset + contentLength
            }
            return contentLength
        }

        return Int64(dataCount)
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
        case progressiveSegment
        case videoSegment
        case audioSegment
    }

    let sessionID: UUID
    let kind: Kind
}

private actor ProxySessionStore {
    struct SessionEntry {
        let stream: PlayableStream
        let createdAt: Date
        var lastAccessedAt: Date
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
        sessions[id] = SessionEntry(stream: stream, createdAt: now, lastAccessedAt: now)
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

    private func purgeExpired(now: Date = Date()) {
        sessions = sessions.filter { _, entry in
            now.timeIntervalSince(entry.lastAccessedAt) < timeout
        }
    }
}
