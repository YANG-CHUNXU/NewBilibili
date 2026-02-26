import Foundation

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
