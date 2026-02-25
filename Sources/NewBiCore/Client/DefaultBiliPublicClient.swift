import Foundation

public final class DefaultBiliPublicClient: BiliPublicClient, @unchecked Sendable {
    private let fetcher: PublicWebFetcher
    private let parser: BiliPublicHTMLParser
    private let cache: VideoCardMemoryCache

    public init(
        fetcher: PublicWebFetcher = PublicWebFetcher(),
        parser: BiliPublicHTMLParser = BiliPublicHTMLParser(),
        cache: VideoCardMemoryCache = VideoCardMemoryCache()
    ) {
        self.fetcher = fetcher
        self.parser = parser
        self.cache = cache
    }

    public func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard] {
        let cacheKey = "sub:\(uid)"
        if let cached = await cache.get(cacheKey) {
            return cached
        }

        var lastError: Error?

        do {
            let fallbackCards = try await fetchSubscriptionVideosFromSpaceArcAPI(uid: uid)
            if !fallbackCards.isEmpty {
                await cache.set(cacheKey, value: fallbackCards)
                return fallbackCards
            }
        } catch {
            lastError = error
        }

        do {
            guard let url = URL(string: "https://space.bilibili.com/\(uid)/video") else {
                throw BiliClientError.invalidInput("无效 UID")
            }
            let html = try await fetcher.fetchHTML(url: url)
            let cards = try parser.parseSubscriptionVideos(from: html)
            if !cards.isEmpty {
                await cache.set(cacheKey, value: cards)
                return cards
            }
        } catch {
            lastError = error
        }

        do {
            let fallbackCards = try await fetchSubscriptionVideosFromDynamicAPI(uid: uid)
            if !fallbackCards.isEmpty {
                await cache.set(cacheKey, value: fallbackCards)
                return fallbackCards
            }
        } catch {
            lastError = error
        }

        if let lastError {
            throw lastError
        }

        return []
    }

    public func searchVideos(keyword: String, page: Int) async throws -> [VideoCard] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BiliClientError.invalidInput("请输入搜索关键词")
        }
        guard (1...3).contains(page) else {
            throw BiliClientError.invalidInput("分页仅支持 1-3")
        }

        let cacheKey = "search:\(trimmed.lowercased()):\(page)"
        if let cached = await cache.get(cacheKey) {
            return cached
        }

        var apiError: Error?
        do {
            let apiCards = try await fetchSearchVideosFromPublicAPI(keyword: trimmed, page: page)
            await cache.set(cacheKey, value: apiCards)
            return apiCards
        } catch {
            // 公开搜索接口可能触发风控，继续尝试 HTML 解析回退。
            apiError = error
        }

        var components = URLComponents(string: "https://search.bilibili.com/video")
        components?.queryItems = [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "page", value: String(page))
        ]

        guard let url = components?.url else {
            throw BiliClientError.invalidInput("搜索参数无效")
        }

        do {
            let html = try await fetcher.fetchHTML(url: url)
            let cards = try parser.parseSearchVideos(from: html)
            if !cards.isEmpty {
                await cache.set(cacheKey, value: cards)
            }
            return cards
        } catch {
            if let apiError {
                throw apiError
            }
            throw error
        }
    }

    public func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        guard !bvid.isEmpty,
              let url = URL(string: "https://www.bilibili.com/video/\(bvid)")
        else {
            throw BiliClientError.invalidInput("无效 bvid")
        }

        let html = try await fetcher.fetchHTML(url: url)
        return try parser.parseVideoDetail(from: html)
    }

    public func resolvePlayableStream(bvid: String, cid: Int?) async throws -> PlayableStream {
        guard !bvid.isEmpty else {
            throw BiliClientError.invalidInput("无效 bvid")
        }

        var components = URLComponents(string: "https://www.bilibili.com/video/\(bvid)")
        if let cid {
            components?.queryItems = [URLQueryItem(name: "cid", value: String(cid))]
        }

        guard let url = components?.url else {
            throw BiliClientError.invalidInput("播放参数无效")
        }

        do {
            let html = try await fetcher.fetchHTML(url: url)
            let parsed = applyPlaybackHeaders(
                to: try parser.parsePlayableStream(from: html),
                bvid: bvid
            )

            if isProgressiveLikeTransport(parsed.transport), !isNativeFriendlyProgressive(parsed) {
                // Some public videos only expose FLV in durl; prefer DASH to avoid AVFoundation -11828.
                return try await resolvePlayableStreamViaPublicAPI(
                    bvid: bvid,
                    cid: cid,
                    preferProgressive: false
                )
            }

            return parsed
        } catch {
            return try await resolvePlayableStreamViaPublicAPI(
                bvid: bvid,
                cid: cid,
                preferProgressive: true
            )
        }
    }

    private func resolvePlayableStreamViaPublicAPI(
        bvid: String,
        cid: Int?,
        preferProgressive: Bool
    ) async throws -> PlayableStream {
        let resolvedCID = try await resolveCIDForPlayback(bvid: bvid, cid: cid)

        if preferProgressive {
            if let progressive = try? await fetchPlayableStreamFromPlayurlAPI(
                bvid: bvid,
                cid: resolvedCID,
                fnval: "0"
            ) {
                let normalized = applyPlaybackHeaders(to: progressive, bvid: bvid)
                if isNativeFriendlyProgressive(normalized) {
                    return normalized
                }
            }
        }

        return applyPlaybackHeaders(
            to: try await fetchPlayableStreamFromPlayurlAPI(
                bvid: bvid,
                cid: resolvedCID,
                fnval: "16"
            ),
            bvid: bvid
        )
    }

    private func fetchPlayableStreamFromPlayurlAPI(
        bvid: String,
        cid: Int,
        fnval: String
    ) async throws -> PlayableStream {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")
        components?.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "qn", value: "80"),
            URLQueryItem(name: "fnver", value: "0"),
            URLQueryItem(name: "fnval", value: fnval),
            URLQueryItem(name: "fourk", value: "1")
        ]
        guard let apiURL = components?.url else {
            throw BiliClientError.invalidInput("播放回退参数无效")
        }

        let headers = [
            "Referer": "https://www.bilibili.com/video/\(bvid)",
            "Origin": "https://www.bilibili.com"
        ]

        do {
            let json = try await fetcher.fetchJSON(url: apiURL, additionalHeaders: headers)
            return try parser.parsePlayableStream(fromPlayInfoJSON: json)
        } catch {
            guard isRateLimitedError(error) else {
                throw error
            }

            await fetcher.primeBilibiliCookiesIfNeeded()
            let retriedJSON = try await fetcher.fetchJSON(url: apiURL, additionalHeaders: headers)
            return try parser.parsePlayableStream(fromPlayInfoJSON: retriedJSON)
        }
    }

    private func resolveCIDForPlayback(bvid: String, cid: Int?) async throws -> Int {
        if let cid {
            return cid
        }

        let detail = try await fetchVideoDetail(bvid: bvid)
        if let first = detail.parts.first?.cid {
            return first
        }

        throw BiliClientError.parseFailed("未找到视频 cid")
    }

    private func applyPlaybackHeaders(to stream: PlayableStream, bvid: String) -> PlayableStream {
        let headers = makePlaybackHeaders(for: bvid)
        let mappedOptions = stream.qualityOptions.map { option in
            PlayableStream(
                transport: option.transport,
                headers: headers,
                qualityID: option.qualityID,
                qualityLabel: option.qualityLabel,
                format: option.format
            )
        }

        return PlayableStream(
            transport: stream.transport,
            headers: headers,
            qualityID: stream.qualityID,
            qualityLabel: stream.qualityLabel,
            format: stream.format,
            qualityOptions: mappedOptions
        )
    }

    private func makePlaybackHeaders(for bvid: String) -> PlaybackHeaders {
        PlaybackHeaders(
            referer: "https://www.bilibili.com/video/\(bvid)",
            origin: "https://www.bilibili.com",
            userAgent: PlaybackHeaders.bilibiliDefault.userAgent
        )
    }

    private func isProgressiveLikeTransport(_ transport: PlayTransport) -> Bool {
        switch transport {
        case .progressive, .progressivePlaylist:
            return true
        case .dash:
            return false
        }
    }

    private func isNativeFriendlyProgressive(_ stream: PlayableStream) -> Bool {
        let sampleURL: URL
        switch stream.transport {
        case .progressive(let url, _):
            sampleURL = url
        case .progressivePlaylist(let segments):
            guard let first = segments.first else {
                return false
            }
            sampleURL = first.url
        case .dash:
            return true
        }

        let format = stream.format.lowercased()
        if format.contains("flv") {
            return false
        }

        let ext = sampleURL.pathExtension.lowercased()
        if ext == "flv" || ext == "f4v" {
            return false
        }

        return true
    }

    private func fetchSubscriptionVideosFromSpaceArcAPI(uid: String) async throws -> [VideoCard] {
        var components = URLComponents(string: "https://api.bilibili.com/x/space/arc/search")
        components?.queryItems = [
            URLQueryItem(name: "mid", value: uid),
            URLQueryItem(name: "pn", value: "1"),
            URLQueryItem(name: "ps", value: "30"),
            URLQueryItem(name: "order", value: "pubdate")
        ]
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("订阅回退参数无效")
        }

        return try await fetchVideoCardsFromPublicJSON(url: url, source: "空间视频")
    }

    private func fetchSubscriptionVideosFromDynamicAPI(uid: String) async throws -> [VideoCard] {
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space")
        components?.queryItems = [
            URLQueryItem(name: "host_mid", value: uid)
        ]
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("动态回退参数无效")
        }

        return try await fetchVideoCardsFromPublicJSON(url: url, source: "动态")
    }

    private func fetchSearchVideosFromPublicAPI(keyword: String, page: Int) async throws -> [VideoCard] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/search/type")
        components?.queryItems = [
            URLQueryItem(name: "search_type", value: "video"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "page", value: String(page))
        ]

        guard let url = components?.url else {
            throw BiliClientError.invalidInput("搜索回退参数无效")
        }

        return try await fetchVideoCardsFromPublicJSON(url: url, source: "搜索")
    }

    private func fetchVideoCardsFromPublicJSON(url: URL, source: String) async throws -> [VideoCard] {
        let json = try await fetcher.fetchJSON(url: url)
        do {
            return try parseVideoCardsFromPublicJSON(json, source: source)
        } catch {
            guard isRateLimitedError(error) else {
                throw error
            }

            await fetcher.primeBilibiliCookiesIfNeeded()
            let retriedJSON = try await fetcher.fetchJSON(url: url)
            return try parseVideoCardsFromPublicJSON(retriedJSON, source: source)
        }
    }

    private func parseVideoCardsFromPublicJSON(_ root: Any, source: String) throws -> [VideoCard] {
        if let top = JSONHelpers.dict(root),
           let code = JSONHelpers.int(top["code"]),
           code != 0
        {
            let message = JSONHelpers.string(top["message"]) ?? JSONHelpers.string(top["msg"]) ?? "未知错误"
            throw mapPublicAPICodeToError(code: code, message: message, source: source)
        }

        var candidateDicts: [[String: Any]] = []
        JSONHelpers.collectDicts(in: root, where: { dict in
            JSONHelpers.string(dict["bvid"]) != nil && JSONHelpers.string(dict["title"]) != nil
        }, output: &candidateDicts)

        var seen = Set<String>()
        var mapped: [VideoCard] = []

        for dict in candidateDicts {
            guard let bvid = JSONHelpers.string(dict["bvid"]), !bvid.isEmpty else {
                continue
            }
            guard seen.insert(bvid).inserted else {
                continue
            }

            let title = decodeHTMLEntities(JSONHelpers.string(dict["title"]) ?? "")
            let author = decodeHTMLEntities(
                JSONHelpers.string(dict["author"]) ??
                JSONHelpers.string(dict["author_name"]) ??
                JSONHelpers.string(dict["name"]) ??
                JSONHelpers.string(dict["uname"]) ??
                "未知UP主"
            )
            let coverURL = normalizeImageURL(
                JSONHelpers.string(dict["pic"]) ??
                JSONHelpers.string(dict["cover"]) ??
                JSONHelpers.string(dict["cover_url"])
            )
            let publishTime =
                JSONHelpers.dateFromTimestamp(dict["created"]) ??
                JSONHelpers.dateFromTimestamp(dict["pubdate"]) ??
                JSONHelpers.dateFromTimestamp(dict["ctime"]) ??
                JSONHelpers.dateFromTimestamp(dict["timestamp"]) ??
                JSONHelpers.dateFromTimestamp(dict["pub_ts"])
            let durationText =
                JSONHelpers.string(dict["length"]) ??
                formatDuration(JSONHelpers.int(dict["duration"]) ?? JSONHelpers.int(dict["duration_seconds"]))

            mapped.append(
                VideoCard(
                    id: bvid,
                    bvid: bvid,
                    title: title,
                    coverURL: coverURL,
                    authorName: author,
                    authorUID: JSONHelpers.string(dict["mid"]) ?? JSONHelpers.string(dict["uid"]) ?? JSONHelpers.string(dict["author_mid"]),
                    durationText: durationText,
                    publishTime: publishTime
                )
            )
        }

        return mapped
    }

    private func mapPublicAPICodeToError(code: Int, message: String, source: String) -> BiliClientError {
        switch code {
        case -352, -412, -509:
            return .rateLimited
        default:
            return .networkFailed("\(source)接口返回异常(code=\(code))：\(message)")
        }
    }

    private func isRateLimitedError(_ error: Error) -> Bool {
        if let known = error as? BiliClientError, known == .rateLimited {
            return true
        }
        return false
    }

    private func normalizeImageURL(_ text: String?) -> URL? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("//") {
            text = "https:\(text)"
        }

        guard let url = URL(string: text) else {
            return nil
        }

        if let scheme = url.scheme?.lowercased(), scheme == "https" {
            return url
        }

        if let scheme = url.scheme?.lowercased(), scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let upgraded = components?.url {
                return upgraded
            }
        }

        return url
    }

    private func formatDuration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else {
            return nil
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
