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

private final class MutableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
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

    func testFetchFollowingVideosFormatsHourAwareDuration() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/x/polymer/web-dynamic/v1/feed/all" else {
                throw URLError(.unsupportedURL)
            }

            return self.jsonResponse(
                url: url,
                body: #"{"code":0,"data":{"has_more":false,"offset":"","items":[{"modules":{"module_author":{"mid":"1001","name":"UP_A","pub_ts":1700000000},"module_dynamic":{"major":{"archive":{"bvid":"BV1HOUR000000","title":"Hour","cover":"//i0.hdslb.com/bfs/archive/hour.jpg","duration":3661}}}}}]}}"#
            )
        }

        let client = makeClient()
        let cards = try await client.fetchFollowingVideos(maxPages: 1)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.durationText, "1:01:01")
    }

    func testFetchFollowingVideosReadsDurationTextField() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/x/polymer/web-dynamic/v1/feed/all" else {
                throw URLError(.unsupportedURL)
            }

            return self.jsonResponse(
                url: url,
                body: #"{"code":0,"data":{"has_more":false,"offset":"","items":[{"modules":{"module_author":{"mid":"1001","name":"UP_A","pub_ts":1700000000},"module_dynamic":{"major":{"archive":{"bvid":"BV1DURTEXT00","title":"DurationText","cover":"//i0.hdslb.com/bfs/archive/hour.jpg","duration_text":"12:34"}}}}}]}}"#
            )
        }

        let client = makeClient()
        let cards = try await client.fetchFollowingVideos(maxPages: 1)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.durationText, "12:34")
    }

    func testFetchVideoDetailUsesPublicAPIViewWhenAvailable() async throws {
        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/x/web-interface/view" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["bvid"], "BV1DETAILAPI0")
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"bvid":"BV1DETAILAPI0","title":"详情接口标题","desc":"详情接口简介","owner":{"name":"UP_DETAIL"},"pages":[{"cid":9001,"page":1,"part":"P1","duration":185}],"stat":{"view":123,"like":45}}}"#
                )
            }

            if url.host == "www.bilibili.com" {
                XCTFail("HTML detail fallback should not be used when public API succeeds")
                throw URLError(.unsupportedURL)
            }

            throw URLError(.unsupportedURL)
        }

        let client = makeClient()
        let detail = try await client.fetchVideoDetail(bvid: "BV1DETAILAPI0")

        XCTAssertEqual(detail.bvid, "BV1DETAILAPI0")
        XCTAssertEqual(detail.title, "详情接口标题")
        XCTAssertEqual(detail.authorName, "UP_DETAIL")
        XCTAssertEqual(detail.parts.count, 1)
        XCTAssertEqual(detail.parts.first?.durationSeconds, 185)
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

    func testFetchFollowingVideosScopesCacheByAccountIdentity() async throws {
        let scopeBox = MutableBox("account-a")
        let requestCount = MutableBox(0)

        ClientStubURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            guard url.path == "/x/polymer/web-dynamic/v1/feed/all" else {
                throw URLError(.unsupportedURL)
            }

            let nextCount = requestCount.get() + 1
            requestCount.set(nextCount)
            if nextCount == 1 {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"has_more":false,"offset":"","items":[{"modules":{"module_author":{"mid":"1001","name":"UP_A","pub_ts":1700000000},"module_dynamic":{"major":{"archive":{"bvid":"BV1A11111111","title":"A","cover":"//i0.hdslb.com/bfs/archive/a.jpg","duration":60}}}}}]}}"#
                )
            }
            if nextCount == 2 {
                return self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"has_more":false,"offset":"","items":[{"modules":{"module_author":{"mid":"1002","name":"UP_B","pub_ts":1700001000},"module_dynamic":{"major":{"archive":{"bvid":"BV1B22222222","title":"B","cover":"//i0.hdslb.com/bfs/archive/b.jpg","duration":60}}}}}]}}"#
                )
            }
            throw URLError(.unsupportedURL)
        }

        let client = makeClient(accountScopeProvider: { scopeBox.get() })

        let first = try await client.fetchFollowingVideos(maxPages: 3)
        XCTAssertEqual(first.map(\.bvid), ["BV1A11111111"])
        XCTAssertEqual(requestCount.get(), 1)

        let second = try await client.fetchFollowingVideos(maxPages: 3)
        XCTAssertEqual(second.map(\.bvid), ["BV1A11111111"])
        XCTAssertEqual(requestCount.get(), 1)

        scopeBox.set("account-b")
        let third = try await client.fetchFollowingVideos(maxPages: 3)
        XCTAssertEqual(third.map(\.bvid), ["BV1B22222222"])
        XCTAssertEqual(requestCount.get(), 2)
    }

    private func makeClient(
        accountScopeProvider: (@Sendable () -> String?)? = nil
    ) -> DefaultBiliPublicClient {
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
            cache: VideoCardMemoryCache(),
            accountScopeProvider: accountScopeProvider
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
