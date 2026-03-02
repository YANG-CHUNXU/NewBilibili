import XCTest
@testable import NewBiCore

final class RequestSchedulerTests: XCTestCase {
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
}
