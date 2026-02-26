import Foundation

public actor InMemorySubscriptionRepository: SubscriptionRepository {
    private var items: [Subscription]

    public init(seed: [Subscription] = []) {
        self.items = seed
    }

    public func list() async throws -> [Subscription] {
        items.sorted(by: { $0.createdAt > $1.createdAt })
    }

    public func add(input: String) async throws -> Subscription {
        let uid = try SubscriptionInputNormalizer.normalizeUID(from: input)
        if let existing = items.first(where: { $0.uid == uid }) {
            return existing
        }
        let subscription = Subscription(
            id: UUID(),
            uid: uid,
            homepageURL: URL(string: "https://space.bilibili.com/\(uid)")!,
            createdAt: Date()
        )
        items.append(subscription)
        return subscription
    }

    public func remove(id: UUID) async throws {
        items.removeAll { $0.id == id }
    }
}

public actor InMemoryWatchHistoryRepository: WatchHistoryRepository {
    private var items: [WatchHistoryRecord]

    public init(seed: [WatchHistoryRecord] = []) {
        self.items = seed
    }

    public func list() async throws -> [WatchHistoryRecord] {
        items.sorted(by: { $0.watchedAt > $1.watchedAt })
    }

    public func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws {
        let now = watchedAt ?? Date()
        if let index = items.firstIndex(where: { $0.bvid == bvid }) {
            let old = items[index]
            items[index] = WatchHistoryRecord(
                id: old.id,
                bvid: bvid,
                title: title,
                watchedAt: now,
                progressSeconds: progressSeconds,
                cid: cid ?? old.cid
            )
            return
        }
        items.append(
            WatchHistoryRecord(
                id: UUID(),
                bvid: bvid,
                title: title,
                watchedAt: now,
                progressSeconds: progressSeconds,
                cid: cid
            )
        )
    }

    public func remove(bvid: String) async throws {
        items.removeAll { $0.bvid == bvid }
    }

    public func clear() async throws {
        items.removeAll()
    }
}
