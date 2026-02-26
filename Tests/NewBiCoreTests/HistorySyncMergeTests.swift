import Foundation
import XCTest
@testable import NewBiCore

final class HistorySyncMergeTests: XCTestCase {
    func testRemoteNewerWatchedAtWins() {
        let local = Date(timeIntervalSince1970: 1_700_000_000)
        let remote = local.addingTimeInterval(60)

        let shouldApply = HistorySyncPolicy.shouldApplyRemote(
            localWatchedAt: local,
            localProgressSeconds: 20,
            remoteWatchedAt: remote,
            remoteProgressSeconds: 10,
            pendingLocalWatchedAt: nil
        )

        XCTAssertTrue(shouldApply)
    }

    func testWhenSameWatchedAtHigherProgressWins() {
        let same = Date(timeIntervalSince1970: 1_700_000_000)

        let shouldApply = HistorySyncPolicy.shouldApplyRemote(
            localWatchedAt: same,
            localProgressSeconds: 20,
            remoteWatchedAt: same,
            remoteProgressSeconds: 25,
            pendingLocalWatchedAt: nil
        )

        XCTAssertTrue(shouldApply)
    }

    func testPendingLocalNewerBlocksRemoteOverride() {
        let local = Date(timeIntervalSince1970: 1_700_000_000)
        let remote = local.addingTimeInterval(30)
        let pending = remote.addingTimeInterval(10)

        let shouldApply = HistorySyncPolicy.shouldApplyRemote(
            localWatchedAt: local,
            localProgressSeconds: 20,
            remoteWatchedAt: remote,
            remoteProgressSeconds: 30,
            pendingLocalWatchedAt: pending
        )

        XCTAssertFalse(shouldApply)
    }

    func testRetentionTrimsTo5000MostRecent() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<5_100).map { index in
            WatchHistoryRecord(
                id: UUID(),
                bvid: "BV\(index)",
                title: "T\(index)",
                watchedAt: base.addingTimeInterval(TimeInterval(index)),
                progressSeconds: Double(index),
                cid: nil
            )
        }

        let trimmed = HistorySyncPolicy.trimToRetention(records: records, limit: 5_000)
        XCTAssertEqual(trimmed.count, 5_000)
        let minWatchedAt = trimmed.map(\.watchedAt).min()
        XCTAssertGreaterThanOrEqual(minWatchedAt ?? .distantPast, base.addingTimeInterval(100))
    }
}
