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

    func record(bvid: String, title: String, progressSeconds: Double) async throws {
        cache.removeAll { $0.bvid == bvid }
        cache.append(
            WatchHistoryRecord(
                id: UUID(),
                bvid: bvid,
                title: title,
                watchedAt: Date(),
                progressSeconds: progressSeconds
            )
        )
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
