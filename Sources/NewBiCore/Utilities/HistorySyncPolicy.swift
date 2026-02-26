import Foundation

public enum HistorySyncPolicy {
    public static func shouldApplyRemote(
        localWatchedAt: Date?,
        localProgressSeconds: Double,
        remoteWatchedAt: Date,
        remoteProgressSeconds: Double,
        pendingLocalWatchedAt: Date?
    ) -> Bool {
        if let pendingLocalWatchedAt, pendingLocalWatchedAt > remoteWatchedAt {
            return false
        }
        guard let localWatchedAt else {
            return true
        }
        if remoteWatchedAt > localWatchedAt {
            return true
        }
        if remoteWatchedAt == localWatchedAt {
            return remoteProgressSeconds > localProgressSeconds
        }
        return false
    }

    public static func backoffDelay(
        step: Int,
        isAuthError: Bool
    ) -> TimeInterval? {
        if isAuthError {
            return nil
        }
        let ladder: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60, 6 * 60 * 60]
        let index = max(0, min(step, ladder.count - 1))
        return ladder[index]
    }

    public static func trimToRetention(
        records: [WatchHistoryRecord],
        limit: Int
    ) -> [WatchHistoryRecord] {
        if records.count <= limit {
            return records
        }
        let sorted = records.sorted { lhs, rhs in
            if lhs.watchedAt != rhs.watchedAt {
                return lhs.watchedAt > rhs.watchedAt
            }
            return lhs.bvid > rhs.bvid
        }
        return Array(sorted.prefix(limit))
    }
}
