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

    func testFetchFollowingVideosSinglePage() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/x/polymer/web-dynamic/v1/feed/all" else {
                throw URLError(.unsupportedURL)
            }

            return self.jsonResponse(
                url: url,
                body: #"{"code":0,"data":{"has_more":false,"offset":"","items":[{"modules":{"module_author":{"mid":"9009","name":"UP_DYNAMIC","pub_ts":1700000300},"module_dynamic":{"major":{"archive":{"bvid":"BV1J99999999","title":"动态投稿","cover":"//i0.hdslb.com/bfs/archive/dynamic.jpg","duration":123}}}}}]}}"#
            )
        }

        let client = makeClient()
        let cards = try await client.fetchFollowingVideos(maxPages: 3)

        XCTAssertEqual(cards.map(\.bvid), ["BV1J99999999"])
        XCTAssertEqual(cards.first?.authorName, "UP_DYNAMIC")
    }

    func testFetchFollowingVideosPaginatesByOffset() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/x/polymer/web-dynamic/v1/feed/all" else {
                throw URLError(.unsupportedURL)
            }

            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = query.first(where: { $0.name == "offset" })?.value
            if offset == nil {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"has_more":1,"offset":"NEXT_1","items":[{"modules":{"module_author":{"mid":"1001","name":"UP_A","pub_ts":1700000000},"module_dynamic":{"major":{"archive":{"bvid":"BV1A11111111","title":"A","cover":"//i0.hdslb.com/bfs/archive/a.jpg","duration":60}}}}}]}}"#
                )
            }
            if offset == "NEXT_1" {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"has_more":0,"offset":"","items":[{"modules":{"module_author":{"mid":"1002","name":"UP_B","pub_ts":1700001000},"module_dynamic":{"major":{"archive":{"bvid":"BV1B22222222","title":"B","cover":"//i0.hdslb.com/bfs/archive/b.jpg","duration":60}}}}}]}}"#
                )
            }
            throw URLError(.unsupportedURL)
        }

        let client = makeClient()
        let cards = try await client.fetchFollowingVideos(maxPages: 3)

        XCTAssertEqual(cards.map(\.bvid), ["BV1B22222222", "BV1A11111111"])
    }

    func testFetchFollowingVideosMapsAuthRequiredCode() async {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            return self.jsonResponse(
                url: url,
                body: #"{"code":-101,"message":"账号未登录"}"#
            )
        }

        let client = makeClient()
        do {
            _ = try await client.fetchFollowingVideos(maxPages: 1)
            XCTFail("expected authRequired")
        } catch let error as BiliClientError {
            XCTAssertEqual(error, .authRequired("账号未登录"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchFollowingVideosMapsRateLimitedCode() async {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            return self.jsonResponse(
                url: url,
                body: #"{"code":-352,"message":"风控"}"#
            )
        }

        let client = makeClient()
        do {
            _ = try await client.fetchFollowingVideos(maxPages: 1)
            XCTFail("expected rateLimited")
        } catch let error as BiliClientError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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
