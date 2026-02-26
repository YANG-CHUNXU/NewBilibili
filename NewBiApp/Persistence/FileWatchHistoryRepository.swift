import Foundation
import NewBiCore

actor FileWatchHistoryRepository: WatchHistoryRepository {
    private let fileURL: URL
    private var cache: [WatchHistoryRecord]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.cache = []
        self.cache = (try? Self.load(url: fileURL, decoder: decoder)) ?? []
    }

    func list() async throws -> [WatchHistoryRecord] {
        cache.sorted { $0.watchedAt > $1.watchedAt }
    }

    func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws {
        let now = watchedAt ?? Date()
        if let index = cache.firstIndex(where: { $0.bvid == bvid }) {
            let old = cache[index]
            cache[index] = WatchHistoryRecord(
                id: old.id,
                bvid: bvid,
                title: title,
                watchedAt: now,
                progressSeconds: progressSeconds,
                cid: cid ?? old.cid
            )
        } else {
            cache.append(
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
        try persist()
    }

    func remove(bvid: String) async throws {
        cache.removeAll { $0.bvid == bvid }
        try persist()
    }

    func clear() async throws {
        cache = []
        try persist()
    }

    private func persist() throws {
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(url: URL, decoder: JSONDecoder) throws -> [WatchHistoryRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([WatchHistoryRecord].self, from: data)
    }
}
