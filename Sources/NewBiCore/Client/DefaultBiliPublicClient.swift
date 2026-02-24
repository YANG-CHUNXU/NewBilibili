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

        var components = URLComponents(string: "https://search.bilibili.com/video")
        components?.queryItems = [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "page", value: String(page))
        ]

        guard let url = components?.url else {
            throw BiliClientError.invalidInput("搜索参数无效")
        }

        let html = try await fetcher.fetchHTML(url: url)
        let cards = try parser.parseSearchVideos(from: html)
        if !cards.isEmpty {
            await cache.set(cacheKey, value: cards)
        }
        return cards
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

        let html = try await fetcher.fetchHTML(url: url)
        return try parser.parsePlayableStream(from: html)
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

        let json = try await fetcher.fetchJSON(url: url)
        return parseVideoCardsFromPublicJSON(json)
    }

    private func fetchSubscriptionVideosFromDynamicAPI(uid: String) async throws -> [VideoCard] {
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space")
        components?.queryItems = [
            URLQueryItem(name: "host_mid", value: uid)
        ]
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("动态回退参数无效")
        }

        let json = try await fetcher.fetchJSON(url: url)
        return parseVideoCardsFromPublicJSON(json)
    }

    private func parseVideoCardsFromPublicJSON(_ root: Any) -> [VideoCard] {
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

    private func normalizeImageURL(_ text: String?) -> URL? {
        guard var text else {
            return nil
        }
        if text.hasPrefix("//") {
            text = "https:\(text)"
        }
        return URL(string: text)
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
