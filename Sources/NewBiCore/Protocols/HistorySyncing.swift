import Foundation

public enum HistoryItemSyncStatus: String, Hashable, Codable, Sendable {
    case localOnly
    case remote
    case synced
    case pendingUpload
    case pendingDelete
    case failed
}

public struct HistorySyncOverview: Hashable, Sendable {
    public let canWrite: Bool
    public let isAuthRequired: Bool
    public let pendingUploadCount: Int
    public let pendingDeleteCount: Int
    public let lastSyncAt: Date?
    public let nextRetryAt: Date?
    public let statusMessage: String?

    public init(
        canWrite: Bool,
        isAuthRequired: Bool,
        pendingUploadCount: Int,
        pendingDeleteCount: Int,
        lastSyncAt: Date?,
        nextRetryAt: Date?,
        statusMessage: String?
    ) {
        self.canWrite = canWrite
        self.isAuthRequired = isAuthRequired
        self.pendingUploadCount = pendingUploadCount
        self.pendingDeleteCount = pendingDeleteCount
        self.lastSyncAt = lastSyncAt
        self.nextRetryAt = nextRetryAt
        self.statusMessage = statusMessage
    }
}

public protocol WatchHistorySyncCoordinator: Sendable {
    func triggerManualSync() async
    func syncOverview() async -> HistorySyncOverview
    func syncStatus(for bvid: String) async -> HistoryItemSyncStatus
}
