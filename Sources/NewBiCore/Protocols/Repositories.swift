import Foundation

public protocol SubscriptionRepository: Sendable {
    func list() async throws -> [Subscription]
    func add(input: String) async throws -> Subscription
    func remove(id: UUID) async throws
}

public protocol WatchHistoryRepository: Sendable {
    func list() async throws -> [WatchHistoryRecord]
    func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws
    func remove(bvid: String) async throws
    func clear() async throws
}

public extension WatchHistoryRepository {
    func record(
        bvid: String,
        title: String,
        progressSeconds: Double
    ) async throws {
        try await record(
            bvid: bvid,
            title: title,
            progressSeconds: progressSeconds,
            watchedAt: nil,
            cid: nil
        )
    }
}

public protocol BiliPublicClient: Sendable {
    func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard]
    func searchVideos(keyword: String, page: Int) async throws -> [VideoCard]
    func fetchVideoDetail(bvid: String) async throws -> VideoDetail
    func resolvePlayableStream(bvid: String, cid: Int?) async throws -> PlayableStream
}
