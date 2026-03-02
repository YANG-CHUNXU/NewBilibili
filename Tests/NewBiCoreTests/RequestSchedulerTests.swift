import XCTest
@testable import NewBiCore

final class RequestSchedulerTests: XCTestCase {
    func testInvalidMaxConcurrentPerHostIsClampedToOne() async {
        await assertInvalidConcurrencyCanAcquire(0)
        await assertInvalidConcurrencyCanAcquire(-3)
    }

    func testCancelledWaiterDoesNotAcquireSlotAfterRelease() async throws {
        let scheduler = RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0)
        let host = "api.bilibili.com"

        try await scheduler.acquire(host: host)

        let waiterStarted = expectation(description: "waiter started")
        let waiter = Task {
            waiterStarted.fulfill()
            try await scheduler.acquire(host: host)
            XCTFail("Cancelled waiter should not acquire slot")
            await scheduler.release(host: host)
        }

        await fulfillment(of: [waiterStarted], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 80_000_000)

        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Expected waiter task to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await scheduler.release(host: host)

        let probeAcquired = expectation(description: "probe acquired")
        let probe = Task {
            do {
                try await scheduler.acquire(host: host)
                await scheduler.release(host: host)
                probeAcquired.fulfill()
            } catch {
                XCTFail("Probe should acquire after cancellation, got \(error)")
            }
        }

        await fulfillment(of: [probeAcquired], timeout: 1.0)
        _ = await probe.result
    }

    private func assertInvalidConcurrencyCanAcquire(_ maxConcurrentPerHost: Int) async {
        let scheduler = RequestScheduler(maxConcurrentPerHost: maxConcurrentPerHost, minIntervalMs: 0)
        let host = "api.bilibili.com"
        let acquired = expectation(description: "acquired with maxConcurrentPerHost=\(maxConcurrentPerHost)")

        let task = Task {
            do {
                try await scheduler.acquire(host: host)
                await scheduler.release(host: host)
                acquired.fulfill()
            } catch {
                XCTFail("Acquire should not fail for invalid maxConcurrentPerHost \(maxConcurrentPerHost), got \(error)")
            }
        }

        await fulfillment(of: [acquired], timeout: 1.0)
        _ = await task.result
    }
}
