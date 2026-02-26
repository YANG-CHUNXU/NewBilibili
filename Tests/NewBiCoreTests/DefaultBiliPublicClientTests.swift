import Foundation
import XCTest
@testable import NewBiCore

private final class ClientStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.requestHandler
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
        requestHandler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
    }
}

final class DefaultBiliPublicClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClientStubURLProtocol.reset()
    }

    override func tearDown() {
        ClientStubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchSubscriptionVideosDynamicFallbackUsesModuleAuthor() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/x/space/arc/search" {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"list":{"vlist":[]}}}"#
                )
            }

            if url.host == "space.bilibili.com" {
                return self.htmlResponse(url: url, statusCode: 500, body: "<html></html>")
            }

            if url.path == "/x/polymer/web-dynamic/v1/feed/space" {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"items":[{"modules":{"module_author":{"mid":"9009","name":"UP_DYNAMIC","pub_ts":1700000300},"module_dynamic":{"major":{"archive":{"bvid":"BV1J99999999","title":"动态投稿","cover":"//i0.hdslb.com/bfs/archive/dynamic.jpg","duration":123}}}}}]}}"#
                )
            }

            throw URLError(.unsupportedURL)
        }

        let client = makeClient()
        let cards = try await client.fetchSubscriptionVideos(uid: "123")

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.bvid, "BV1J99999999")
        XCTAssertEqual(cards.first?.authorName, "UP_DYNAMIC")
        XCTAssertEqual(cards.first?.authorUID, "9009")
    }

    private func makeClient() -> DefaultBiliPublicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientStubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let fetcher = PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0)
        )
        return DefaultBiliPublicClient(
            fetcher: fetcher,
            parser: BiliPublicHTMLParser(),
            cache: VideoCardMemoryCache()
        )
    }

    private func jsonResponse(url: URL, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private func htmlResponse(url: URL, statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        return (response, Data(body.utf8))
    }
}
