import Foundation

public struct RemoteHistoryKey: Hashable, Codable, Sendable {
    public let bvid: String

    public init(bvid: String) {
        self.bvid = bvid
    }
}

public struct RemoteHistoryItem: Hashable, Codable, Sendable {
    public let key: RemoteHistoryKey
    public let bvid: String
    public let title: String
    public let progressSeconds: Double
    public let watchedAt: Date
    public let cid: Int?
    public let durationSeconds: Double?

    public init(
        key: RemoteHistoryKey,
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date,
        cid: Int?,
        durationSeconds: Double?
    ) {
        self.key = key
        self.bvid = bvid
        self.title = title
        self.progressSeconds = progressSeconds
        self.watchedAt = watchedAt
        self.cid = cid
        self.durationSeconds = durationSeconds
    }
}

public struct HistoryCursor: Hashable, Codable, Sendable {
    public let max: Int?
    public let viewAt: Int?
    public let business: String?

    public init(max: Int?, viewAt: Int?, business: String?) {
        self.max = max
        self.viewAt = viewAt
        self.business = business
    }
}

public struct HistoryFetchResult: Hashable, Sendable {
    public let items: [RemoteHistoryItem]
    public let nextCursor: HistoryCursor?
    public let hasMore: Bool

    public init(items: [RemoteHistoryItem], nextCursor: HistoryCursor?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct HistoryProgressReport: Hashable, Sendable {
    public let bvid: String
    public let cid: Int?
    public let progressSeconds: Double
    public let watchedAt: Date
    public let csrf: String

    public init(
        bvid: String,
        cid: Int?,
        progressSeconds: Double,
        watchedAt: Date,
        csrf: String
    ) {
        self.bvid = bvid
        self.cid = cid
        self.progressSeconds = progressSeconds
        self.watchedAt = watchedAt
        self.csrf = csrf
    }
}
