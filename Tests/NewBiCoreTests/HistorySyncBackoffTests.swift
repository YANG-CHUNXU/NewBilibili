import Foundation
import XCTest
@testable import NewBiCore

final class HistorySyncBackoffTests: XCTestCase {
    func testBackoffStepLadder() {
        XCTAssertEqual(HistorySyncPolicy.backoffDelay(step: 0, isAuthError: false), 60)
        XCTAssertEqual(HistorySyncPolicy.backoffDelay(step: 1, isAuthError: false), 300)
        XCTAssertEqual(HistorySyncPolicy.backoffDelay(step: 2, isAuthError: false), 900)
        XCTAssertEqual(HistorySyncPolicy.backoffDelay(step: 3, isAuthError: false), 3600)
        XCTAssertEqual(HistorySyncPolicy.backoffDelay(step: 10, isAuthError: false), 21600)
    }

    func testAuthErrorHasNoTimedBackoff() {
        XCTAssertNil(HistorySyncPolicy.backoffDelay(step: 0, isAuthError: true))
        XCTAssertNil(HistorySyncPolicy.backoffDelay(step: 3, isAuthError: true))
    }
}
