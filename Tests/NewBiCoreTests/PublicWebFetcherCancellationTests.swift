import Foundation
import XCTest
@testable import NewBiCore

private final class FetcherCancellationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func prepare(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        self.requestCount = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        self.handler = nil
        self.requestCount = 0
        lock.unlock()
    }

    static func servedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }
}

final class PublicWebFetcherCancellationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FetcherCancellationURLProtocol.reset()
    }

    override func tearDown() {
        FetcherCancellationURLProtocol.reset()
        super.tearDown()
    }

    func testCancelledNSErrorIsPropagatedAsCancellationError() async {
        FetcherCancellationURLProtocol.prepare { _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        }

        let fetcher = makeFetcher()
        do {
            _ = try await fetcher.fetchJSON(url: URL(string: "https://api.bilibili.com/x/test")!)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancelDuringRetrySleepStopsFurtherRetries() async {
        let firstRequest = expectation(description: "first request")
        firstRequest.assertForOverFulfill = false
        FetcherCancellationURLProtocol.prepare { request in
            firstRequest.fulfill()
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let fetcher = makeFetcher()
        let task = Task {
            try await fetcher.fetchJSON(url: URL(string: "https://api.bilibili.com/x/test")!)
        }

        await fulfillment(of: [firstRequest], timeout: 1.0)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(FetcherCancellationURLProtocol.servedRequestCount(), 1)
    }

    private func makeFetcher() -> PublicWebFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FetcherCancellationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0)
        )
    }
}
