import Foundation
import XCTest
@testable import NewBiCore

private final class WarmupURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest, Int) throws -> (HTTPURLResponse, Data))?
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
        let currentAttempt = Self.requestCount
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request, currentAttempt)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func prepare(handler: @escaping (URLRequest, Int) throws -> (HTTPURLResponse, Data)) {
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

final class PublicWebFetcherWarmupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WarmupURLProtocol.reset()
    }

    override func tearDown() {
        WarmupURLProtocol.reset()
        super.tearDown()
    }

    func testFailedWarmupRetriesUntilSuccessThenRespectsWindow() async {
        WarmupURLProtocol.prepare { request, attempt in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if attempt == 1 {
                // Use non-retriable URL error so one prime call only sends one request.
                throw URLError(.badURL)
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html></html>".utf8))
        }

        let fetcher = makeFetcher()
        await fetcher.primeBilibiliCookiesIfNeeded()
        await fetcher.primeBilibiliCookiesIfNeeded()
        await fetcher.primeBilibiliCookiesIfNeeded()

        XCTAssertEqual(WarmupURLProtocol.servedRequestCount(), 2)
    }

    private func makeFetcher() -> PublicWebFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WarmupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0)
        )
    }
}
