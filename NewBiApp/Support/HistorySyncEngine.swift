import Foundation
import NewBiCore

private struct PendingHistoryUpsert: Hashable, Codable, Sendable {
    let bvid: String
    let title: String
    let progressSeconds: Double
    let watchedAt: Date
    let cid: Int?
}

private struct MirrorHistoryEntry: Hashable, Codable, Sendable {
    let key: RemoteHistoryKey
    let watchedAt: Date
    let updatedAt: Date
}

private struct HistorySyncMeta: Codable, Sendable {
    var cursor: HistoryCursor?
    var pendingUpserts: [String: PendingHistoryUpsert]
    var pendingDeletes: [String: RemoteHistoryKey]
    var tombstones: Set<String>
    var mirrorIndex: [String: MirrorHistoryEntry]
    var remoteKnownBVIDs: Set<String>
    var failedBVIDs: Set<String>
    var lastSweepAt: Date?
    var lastSyncAt: Date?
    var nextRetryAt: Date?
    var backoffStep: Int
    var isAuthRequired: Bool
    var statusMessage: String?
    var initialBackfillCompleted: Bool

    static let empty = HistorySyncMeta(
        cursor: nil,
        pendingUpserts: [:],
        pendingDeletes: [:],
        tombstones: [],
        mirrorIndex: [:],
        remoteKnownBVIDs: [],
        failedBVIDs: [],
        lastSweepAt: nil,
        lastSyncAt: nil,
        nextRetryAt: nil,
        backoffStep: 0,
        isAuthRequired: false,
        statusMessage: nil,
        initialBackfillCompleted: false
    )
}

actor HistorySyncEngine: WatchHistorySyncCoordinator {
    private let historyClient: any BiliHistoryClient
    private let localRepository: any WatchHistoryRepository
    private let credentialProvider: @Sendable () -> BiliCredential?
    private let metaURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let syncInterval: TimeInterval
    private let retentionLimit: Int
    private let maxIncrementalPages = 5
    private let maxSweepPages = 10

    private var meta: HistorySyncMeta
    private var isSyncing = false
    private var lastSyncAttemptAt: Date?

    init(
        historyClient: any BiliHistoryClient,
        localRepository: any WatchHistoryRepository,
        credentialProvider: @escaping @Sendable () -> BiliCredential?,
        metaURL: URL,
        syncInterval: TimeInterval = 3600,
        retentionLimit: Int = 5000
    ) {
        self.historyClient = historyClient
        self.localRepository = localRepository
        self.credentialProvider = credentialProvider
        self.metaURL = metaURL
        self.syncInterval = syncInterval
        self.retentionLimit = retentionLimit
        self.meta = Self.loadMeta(url: metaURL, decoder: decoder) ?? .empty
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func recordLocalChange(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date,
        cid: Int?
    ) async {
        meta.pendingDeletes.removeValue(forKey: bvid)
        meta.tombstones.remove(bvid)
        meta.failedBVIDs.remove(bvid)
        meta.pendingUpserts[bvid] = PendingHistoryUpsert(
            bvid: bvid,
            title: title,
            progressSeconds: progressSeconds,
            watchedAt: watchedAt,
            cid: cid
        )
        persistMeta()
    }

    func recordLocalDelete(bvid: String) async {
        meta.pendingUpserts.removeValue(forKey: bvid)
        meta.failedBVIDs.remove(bvid)
        meta.tombstones.insert(bvid)
        let key = meta.mirrorIndex[bvid]?.key ?? RemoteHistoryKey(bvid: bvid)
        meta.pendingDeletes[bvid] = key
        persistMeta()
    }

    func recordLocalClear() async {
        meta.pendingUpserts.removeAll()
        meta.failedBVIDs.removeAll()
        for (bvid, entry) in meta.mirrorIndex {
            meta.pendingDeletes[bvid] = entry.key
            meta.tombstones.insert(bvid)
        }
        persistMeta()
    }

    func triggerStartupSync() async {
        await syncNow(force: true)
    }

    func triggerPeriodicSyncIfNeeded() async {
        let now = Date()
        if let lastSyncAt = meta.lastSyncAt, now.timeIntervalSince(lastSyncAt) < syncInterval {
            return
        }
        await syncNow(force: false)
    }

    func triggerMutationSync() async {
        await syncNow(force: false)
    }

    func triggerManualSync() async {
        await syncNow(force: true)
    }

    func syncOverview() async -> HistorySyncOverview {
        let credential = credentialProvider()
        return HistorySyncOverview(
            canWrite: credential?.canWriteHistory == true,
            isAuthRequired: meta.isAuthRequired,
            pendingUploadCount: meta.pendingUpserts.count,
            pendingDeleteCount: meta.pendingDeletes.count,
            lastSyncAt: meta.lastSyncAt,
            nextRetryAt: meta.nextRetryAt,
            statusMessage: meta.statusMessage
        )
    }

    func syncStatus(for bvid: String) async -> HistoryItemSyncStatus {
        if meta.pendingDeletes[bvid] != nil {
            return .pendingDelete
        }
        if meta.pendingUpserts[bvid] != nil {
            return .pendingUpload
        }
        if meta.failedBVIDs.contains(bvid) {
            return .failed
        }
        if meta.mirrorIndex[bvid] != nil {
            return .synced
        }
        if meta.remoteKnownBVIDs.contains(bvid) {
            return .remote
        }
        return .localOnly
    }

    private func syncNow(force: Bool) async {
        if isSyncing {
            return
        }
        let now = Date()
        if !force, let lastSyncAttemptAt, now.timeIntervalSince(lastSyncAttemptAt) < 4 {
            return
        }
        if !force, let nextRetryAt = meta.nextRetryAt, now < nextRetryAt {
            return
        }

        lastSyncAttemptAt = now
        isSyncing = true
        defer { isSyncing = false }

        guard let credential = credentialProvider() else {
            meta.statusMessage = "未登录，无法同步历史"
            persistMeta()
            return
        }

        do {
            if credential.canWriteHistory {
                try await ensureInitialBackfillIfNeeded()
                try await flushPendingDeletes(csrf: credential.biliJct ?? "")
                try await flushPendingUpserts(csrf: credential.biliJct ?? "")
            }

            try await pullIncrementalHistory()
            try await sweepRecentHistoryIfNeeded()
            try await pruneLocalHistoryIfNeeded()

            meta.lastSyncAt = Date()
            meta.nextRetryAt = nil
            meta.backoffStep = 0
            meta.isAuthRequired = false
            meta.statusMessage = nil
            meta.failedBVIDs.removeAll()
            persistMeta()
        } catch {
            applyBackoff(for: error)
            persistMeta()
        }
    }

    private func ensureInitialBackfillIfNeeded() async throws {
        guard !meta.initialBackfillCompleted else {
            return
        }
        let local = try await localRepository.list()
        for item in local {
            meta.pendingUpserts[item.bvid] = PendingHistoryUpsert(
                bvid: item.bvid,
                title: item.title,
                progressSeconds: item.progressSeconds,
                watchedAt: item.watchedAt,
                cid: item.cid
            )
        }
        meta.initialBackfillCompleted = true
    }

    private func flushPendingDeletes(csrf: String) async throws {
        guard !csrf.isEmpty else {
            throw BiliClientError.authRequired("缺少 bili_jct")
        }
        let sorted = meta.pendingDeletes.keys.sorted()
        for bvid in sorted {
            guard let key = meta.pendingDeletes[bvid] else {
                continue
            }
            do {
                try await historyClient.deleteHistory(key: key, csrf: csrf)
                meta.pendingDeletes.removeValue(forKey: bvid)
                meta.tombstones.remove(bvid)
                meta.mirrorIndex.removeValue(forKey: bvid)
                meta.remoteKnownBVIDs.remove(bvid)
                meta.failedBVIDs.remove(bvid)
            } catch {
                meta.failedBVIDs.insert(bvid)
                throw error
            }
        }
    }

    private func flushPendingUpserts(csrf: String) async throws {
        guard !csrf.isEmpty else {
            throw BiliClientError.authRequired("缺少 bili_jct")
        }

        let sorted = meta.pendingUpserts.values.sorted { lhs, rhs in
            if lhs.watchedAt != rhs.watchedAt {
                return lhs.watchedAt < rhs.watchedAt
            }
            return lhs.bvid < rhs.bvid
        }

        for entry in sorted {
            do {
                try await historyClient.reportProgress(
                    HistoryProgressReport(
                        bvid: entry.bvid,
                        cid: entry.cid,
                        progressSeconds: entry.progressSeconds,
                        watchedAt: entry.watchedAt,
                        csrf: csrf
                    )
                )
                meta.pendingUpserts.removeValue(forKey: entry.bvid)
                meta.failedBVIDs.remove(entry.bvid)
                meta.remoteKnownBVIDs.insert(entry.bvid)
                meta.mirrorIndex[entry.bvid] = MirrorHistoryEntry(
                    key: RemoteHistoryKey(bvid: entry.bvid),
                    watchedAt: entry.watchedAt,
                    updatedAt: Date()
                )
            } catch {
                meta.failedBVIDs.insert(entry.bvid)
                throw error
            }
        }
    }

    private func pullIncrementalHistory() async throws {
        var cursor = meta.cursor
        var page = 0
        var hasMore = true
        var latestCursor = meta.cursor
        var localMap = try await makeLocalMap()

        while hasMore, page < maxIncrementalPages {
            let result = try await historyClient.fetchHistory(cursor: cursor)
            if result.items.isEmpty {
                latestCursor = result.nextCursor ?? latestCursor
                break
            }
            for item in result.items {
                try await mergeRemoteItem(item, localMap: &localMap)
            }
            hasMore = result.hasMore
            cursor = result.nextCursor
            latestCursor = result.nextCursor ?? latestCursor
            page += 1
        }

        meta.cursor = latestCursor
    }

    private func sweepRecentHistoryIfNeeded() async throws {
        let now = Date()
        if let lastSweepAt = meta.lastSweepAt,
           now.timeIntervalSince(lastSweepAt) < 24 * 60 * 60
        {
            return
        }

        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var cursor: HistoryCursor?
        var page = 0
        var hasMore = true
        var localMap = try await makeLocalMap()
        var seenRecent: Set<String> = []

        while hasMore, page < maxSweepPages {
            let result = try await historyClient.fetchHistory(cursor: cursor)
            if result.items.isEmpty {
                break
            }
            for item in result.items {
                if item.watchedAt >= cutoff {
                    seenRecent.insert(item.bvid)
                }
                try await mergeRemoteItem(item, localMap: &localMap)
            }
            if let minDate = result.items.map(\.watchedAt).min(), minDate < cutoff {
                hasMore = false
            } else {
                hasMore = result.hasMore
                cursor = result.nextCursor
            }
            page += 1
        }

        let candidates = meta.mirrorIndex.values.filter { $0.watchedAt >= cutoff }
        for entry in candidates {
            let bvid = entry.key.bvid
            guard !seenRecent.contains(bvid),
                  meta.pendingUpserts[bvid] == nil,
                  !meta.tombstones.contains(bvid)
            else {
                continue
            }
            try await localRepository.remove(bvid: bvid)
            meta.mirrorIndex.removeValue(forKey: bvid)
            meta.remoteKnownBVIDs.remove(bvid)
            meta.failedBVIDs.remove(bvid)
            meta.pendingDeletes.removeValue(forKey: bvid)
        }

        meta.lastSweepAt = now
    }

    private func mergeRemoteItem(
        _ item: RemoteHistoryItem,
        localMap: inout [String: WatchHistoryRecord]
    ) async throws {
        if meta.tombstones.contains(item.bvid) {
            return
        }

        let local = localMap[item.bvid]
        let shouldApplyRemote = HistorySyncPolicy.shouldApplyRemote(
            localWatchedAt: local?.watchedAt,
            localProgressSeconds: local?.progressSeconds ?? 0,
            remoteWatchedAt: item.watchedAt,
            remoteProgressSeconds: item.progressSeconds,
            pendingLocalWatchedAt: meta.pendingUpserts[item.bvid]?.watchedAt
        )

        if shouldApplyRemote {
            let title = item.title.isEmpty ? (localMap[item.bvid]?.title ?? item.bvid) : item.title
            try await localRepository.record(
                bvid: item.bvid,
                title: title,
                progressSeconds: item.progressSeconds,
                watchedAt: item.watchedAt,
                cid: item.cid
            )
            localMap[item.bvid] = WatchHistoryRecord(
                id: localMap[item.bvid]?.id ?? UUID(),
                bvid: item.bvid,
                title: title,
                watchedAt: item.watchedAt,
                progressSeconds: item.progressSeconds,
                cid: item.cid ?? localMap[item.bvid]?.cid
            )
        }

        meta.remoteKnownBVIDs.insert(item.bvid)
        meta.mirrorIndex[item.bvid] = MirrorHistoryEntry(
            key: item.key,
            watchedAt: item.watchedAt,
            updatedAt: Date()
        )
    }

    private func pruneLocalHistoryIfNeeded() async throws {
        let list = try await localRepository.list()
        guard list.count > retentionLimit else {
            return
        }

        let overflow = list.dropFirst(retentionLimit)
        for item in overflow {
            try await localRepository.remove(bvid: item.bvid)
            meta.pendingUpserts.removeValue(forKey: item.bvid)
            meta.pendingDeletes.removeValue(forKey: item.bvid)
            meta.failedBVIDs.remove(item.bvid)
            meta.tombstones.remove(item.bvid)
        }
    }

    private func makeLocalMap() async throws -> [String: WatchHistoryRecord] {
        let records = try await localRepository.list()
        return Dictionary(uniqueKeysWithValues: records.map { ($0.bvid, $0) })
    }

    private func applyBackoff(for error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        meta.statusMessage = message

        if let known = error as? BiliClientError, case .authRequired = known {
            meta.isAuthRequired = true
            meta.nextRetryAt = Date().addingTimeInterval(60 * 60)
            return
        }

        let delay = HistorySyncPolicy.backoffDelay(step: meta.backoffStep, isAuthError: false) ?? 60
        meta.nextRetryAt = Date().addingTimeInterval(delay)
        meta.backoffStep = min(meta.backoffStep + 1, 4)
    }

    private func persistMeta() {
        do {
            let data = try encoder.encode(meta)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            return
        }
    }

    private static func loadMeta(url: URL, decoder: JSONDecoder) -> HistorySyncMeta? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(HistorySyncMeta.self, from: data)
        } catch {
            return nil
        }
    }
}

actor SyncingWatchHistoryRepository: WatchHistoryRepository {
    private let localRepository: any WatchHistoryRepository
    private let syncEngine: HistorySyncEngine

    init(
        localRepository: any WatchHistoryRepository,
        syncEngine: HistorySyncEngine
    ) {
        self.localRepository = localRepository
        self.syncEngine = syncEngine
    }

    func list() async throws -> [WatchHistoryRecord] {
        try await localRepository.list()
    }

    func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws {
        let effectiveWatchedAt = watchedAt ?? Date()
        try await localRepository.record(
            bvid: bvid,
            title: title,
            progressSeconds: progressSeconds,
            watchedAt: effectiveWatchedAt,
            cid: cid
        )
        await syncEngine.recordLocalChange(
            bvid: bvid,
            title: title,
            progressSeconds: progressSeconds,
            watchedAt: effectiveWatchedAt,
            cid: cid
        )
        await syncEngine.triggerMutationSync()
    }

    func remove(bvid: String) async throws {
        try await localRepository.remove(bvid: bvid)
        await syncEngine.recordLocalDelete(bvid: bvid)
        await syncEngine.triggerMutationSync()
    }

    func clear() async throws {
        try await localRepository.clear()
        await syncEngine.recordLocalClear()
        await syncEngine.triggerMutationSync()
    }
}
