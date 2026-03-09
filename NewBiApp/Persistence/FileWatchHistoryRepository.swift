import Foundation
import os
import NewBiCore

private enum FileWatchHistoryRepositoryError: LocalizedError {
    case initialLoadFailed(fileURL: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .initialLoadFailed:
            return "读取本地观看历史失败，除清空历史外的读写已阻止以避免覆盖已有数据。"
        }
    }

    var failureReason: String? {
        switch self {
        case .initialLoadFailed(_, let underlying):
            return underlying.localizedDescription
        }
    }

    var recoverySuggestion: String? {
        "可在应用内执行“清空历史”重建文件，或从备份恢复后重试。"
    }
}

actor FileWatchHistoryRepository: WatchHistoryRepository {
    private static let logger = Logger(subsystem: "com.ycx.newbi", category: "FileWatchHistoryRepository")

    private let fileURL: URL
    private var cache: [WatchHistoryRecord]
    private var loadError: FileWatchHistoryRepositoryError?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL) {
        self.fileURL = fileURL

        let initialCache: [WatchHistoryRecord]
        let initialLoadError: FileWatchHistoryRepositoryError?
        do {
            initialCache = try Self.load(url: fileURL, decoder: decoder)
            initialLoadError = nil
        } catch {
            let wrapped = FileWatchHistoryRepositoryError.initialLoadFailed(fileURL: fileURL, underlying: error)
            Self.logger.error(
                "Failed to load watch history [path=\(fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)]"
            )
            initialCache = []
            initialLoadError = wrapped
        }
        self.cache = initialCache
        self.loadError = initialLoadError
    }

    func list() async throws -> [WatchHistoryRecord] {
        try ensureLoadSucceeded()
        return cache.sorted { $0.watchedAt > $1.watchedAt }
    }

    func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws {
        try ensureLoadSucceeded()
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
        try ensureLoadSucceeded()
        cache.removeAll { $0.bvid == bvid }
        try persist()
    }

    func clear() async throws {
        let hadLoadError = (loadError != nil)
        cache = []
        try persist()
        if hadLoadError {
            Self.logger.notice("Watch history store recovered by clear [path=\(self.fileURL.path, privacy: .public)]")
        }
        loadError = nil
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

    private func ensureLoadSucceeded() throws {
        guard loadError != nil else {
            return
        }

        do {
            cache = try Self.load(url: fileURL, decoder: decoder)
            loadError = nil
            Self.logger.notice("Watch history store recovered by reload [path=\(self.fileURL.path, privacy: .public)]")
        } catch {
            let wrapped = FileWatchHistoryRepositoryError.initialLoadFailed(fileURL: fileURL, underlying: error)
            loadError = wrapped
            throw wrapped
        }
    }
}
