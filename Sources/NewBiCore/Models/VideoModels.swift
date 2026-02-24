import Foundation

public struct VideoCard: Identifiable, Hashable, Sendable {
    public let id: String
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let authorName: String
    public let authorUID: String?
    public let durationText: String?
    public let publishTime: Date?

    public init(
        id: String,
        bvid: String,
        title: String,
        coverURL: URL?,
        authorName: String,
        authorUID: String?,
        durationText: String?,
        publishTime: Date?
    ) {
        self.id = id
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.authorName = authorName
        self.authorUID = authorUID
        self.durationText = durationText
        self.publishTime = publishTime
    }
}

public struct VideoPart: Hashable, Sendable {
    public let cid: Int
    public let page: Int
    public let title: String
    public let durationSeconds: Int?

    public init(cid: Int, page: Int, title: String, durationSeconds: Int?) {
        self.cid = cid
        self.page = page
        self.title = title
        self.durationSeconds = durationSeconds
    }
}

public struct VideoStats: Hashable, Sendable {
    public let view: Int?
    public let danmaku: Int?
    public let reply: Int?
    public let favorite: Int?
    public let coin: Int?
    public let share: Int?
    public let like: Int?

    public init(
        view: Int?,
        danmaku: Int?,
        reply: Int?,
        favorite: Int?,
        coin: Int?,
        share: Int?,
        like: Int?
    ) {
        self.view = view
        self.danmaku = danmaku
        self.reply = reply
        self.favorite = favorite
        self.coin = coin
        self.share = share
        self.like = like
    }
}

public struct VideoDetail: Hashable, Sendable {
    public let bvid: String
    public let title: String
    public let description: String?
    public let authorName: String
    public let parts: [VideoPart]
    public let stats: VideoStats?

    public init(
        bvid: String,
        title: String,
        description: String?,
        authorName: String,
        parts: [VideoPart],
        stats: VideoStats?
    ) {
        self.bvid = bvid
        self.title = title
        self.description = description
        self.authorName = authorName
        self.parts = parts
        self.stats = stats
    }
}

public struct PlaybackHeaders: Hashable, Sendable {
    public let referer: String
    public let origin: String
    public let userAgent: String

    public init(referer: String, origin: String, userAgent: String) {
        self.referer = referer
        self.origin = origin
        self.userAgent = userAgent
    }

    public static let bilibiliDefault = PlaybackHeaders(
        referer: "https://www.bilibili.com",
        origin: "https://www.bilibili.com",
        userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    )
}

public enum PlayTransport: Hashable, Sendable {
    case progressive(url: URL)
    case dash(videoURL: URL, audioURL: URL?)
}

public struct PlayableStream: Hashable, Sendable {
    public let transport: PlayTransport
    public let headers: PlaybackHeaders
    public let qualityLabel: String
    public let format: String

    public init(transport: PlayTransport, headers: PlaybackHeaders, qualityLabel: String, format: String) {
        self.transport = transport
        self.headers = headers
        self.qualityLabel = qualityLabel
        self.format = format
    }

    public init(url: URL, qualityLabel: String, format: String) {
        self.transport = .progressive(url: url)
        self.headers = .bilibiliDefault
        self.qualityLabel = qualityLabel
        self.format = format
    }
}

public struct WatchHistoryRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let bvid: String
    public let title: String
    public let watchedAt: Date
    public let progressSeconds: Double

    public init(id: UUID, bvid: String, title: String, watchedAt: Date, progressSeconds: Double) {
        self.id = id
        self.bvid = bvid
        self.title = title
        self.watchedAt = watchedAt
        self.progressSeconds = progressSeconds
    }
}
