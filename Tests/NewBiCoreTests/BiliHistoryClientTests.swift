import Foundation
import XCTest
@testable import NewBiCore

private final class BiliHistoryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
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

    static func prepare(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        self.lastRequest = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }
}

final class BiliHistoryClientTests: XCTestCase {
    func testFetchHistoryParsesItemsAndCursor() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/web-interface/history/cursor")
            let json = """
            {"code":0,"data":{"cursor":{"max":123,"view_at":456,"business":"archive","has_more":true},"list":[{"bvid":"BV1xx","title":"标题A","progress":9,"view_at":1735646400,"history":{"cid":11,"duration":120}}]}}
            """
            return self.response(request.url!, json: json)
        }

        let result = try await client.fetchHistory(cursor: nil)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.bvid, "BV1xx")
        XCTAssertEqual(result.items.first?.cid, 11)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.nextCursor?.max, 123)
    }

    func testFetchHistoryInitialRequestIncludesDefaultCursorFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/web-interface/history/cursor")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(queryMap["ps"], "30")
            XCTAssertEqual(queryMap["max"], "0")
            XCTAssertEqual(queryMap["view_at"], "0")
            XCTAssertEqual(queryMap["business"], "archive")
            let json = #"{"code":0,"data":{"cursor":{"max":1,"view_at":1,"business":"archive","has_more":false},"list":[]}}"#
            return self.response(request.url!, json: json)
        }

        _ = try await client.fetchHistory(cursor: nil)
    }

    func testReportProgressUsesPostFormBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/v2/history/report")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = self.bodyString(from: request)
            XCTAssertTrue(body.contains("csrf=csrf123"))
            XCTAssertTrue(body.contains("bvid=BV1xx"))
            XCTAssertTrue(body.contains("progress=15"))
            let json = #"{"code":0,"data":{}}"#
            return self.response(request.url!, json: json)
        }

        try await client.reportProgress(
            HistoryProgressReport(
                bvid: "BV1xx",
                cid: 100,
                progressSeconds: 15,
                watchedAt: Date(timeIntervalSince1970: 1_735_646_400),
                csrf: "csrf123"
            )
        )
    }

    func testDeleteHistoryMapsAuthError() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/v2/history/delete")
            let json = #"{"code":-101,"message":"not login"}"#
            return self.response(request.url!, json: json)
        }

        do {
            try await client.deleteHistory(key: RemoteHistoryKey(bvid: "BV1xx"), csrf: "csrf123")
            XCTFail("Expected error")
        } catch let error as BiliClientError {
            switch error {
            case .authRequired(let message):
                XCTAssertTrue(message.contains("not login"))
            default:
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testReportProgressRetriesWithAidAndCidWhenCodeMinus400() async throws {
        var step = 0
        let client = makeClient { request in
            step += 1
            switch step {
            case 1:
                XCTAssertEqual(request.url?.path, "/x/v2/history/report")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = self.bodyString(from: request)
                XCTAssertTrue(body.contains("bvid=BV1retry"))
                XCTAssertFalse(body.contains("aid="))
                let json = #"{"code":-400,"message":"请求错误"}"#
                return self.response(request.url!, json: json)
            case 2:
                XCTAssertEqual(request.url?.path, "/x/web-interface/view")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["bvid"], "BV1retry")
                let json = #"{"code":0,"data":{"aid":123456,"cid":654321}}"#
                return self.response(request.url!, json: json)
            case 3:
                XCTAssertEqual(request.url?.path, "/x/v2/history/report")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = self.bodyString(from: request)
                XCTAssertTrue(body.contains("bvid=BV1retry"))
                XCTAssertTrue(body.contains("aid=123456"))
                XCTAssertTrue(body.contains("cid=654321"))
                let json = #"{"code":0,"data":{}}"#
                return self.response(request.url!, json: json)
            default:
                XCTFail("Unexpected request step \(step)")
                throw URLError(.badServerResponse)
            }
        }

        try await client.reportProgress(
            HistoryProgressReport(
                bvid: "BV1retry",
                cid: nil,
                progressSeconds: 22,
                watchedAt: Date(timeIntervalSince1970: 1_735_646_500),
                csrf: "csrf123"
            )
        )
        XCTAssertEqual(step, 3)
    }

    func testReportProgressFallsBackToMinimalPayloadWhenStillCodeMinus400() async throws {
        var step = 0
        let client = makeClient { request in
            step += 1
            switch step {
            case 1:
                XCTAssertEqual(request.url?.path, "/x/v2/history/report")
                let json = #"{"code":-400,"message":"请求错误"}"#
                return self.response(request.url!, json: json)
            case 2:
                XCTAssertEqual(request.url?.path, "/x/web-interface/view")
                let json = #"{"code":0,"data":{"aid":223344,"cid":445566}}"#
                return self.response(request.url!, json: json)
            case 3:
                XCTAssertEqual(request.url?.path, "/x/v2/history/report")
                let body = self.bodyString(from: request)
                XCTAssertTrue(body.contains("aid=223344"))
                XCTAssertTrue(body.contains("cid=445566"))
                XCTAssertTrue(body.contains("platform=ios"))
                let json = #"{"code":-400,"message":"请求错误"}"#
                return self.response(request.url!, json: json)
            case 4:
                XCTAssertEqual(request.url?.path, "/x/v2/history/report")
                let body = self.bodyString(from: request)
                XCTAssertTrue(body.contains("aid=223344"))
                XCTAssertTrue(body.contains("cid=445566"))
                XCTAssertFalse(body.contains("platform=ios"))
                XCTAssertFalse(body.contains("bvid=BV1retry2"))
                let json = #"{"code":0,"data":{}}"#
                return self.response(request.url!, json: json)
            default:
                XCTFail("Unexpected request step \(step)")
                throw URLError(.badServerResponse)
            }
        }

        try await client.reportProgress(
            HistoryProgressReport(
                bvid: "BV1retry2",
                cid: nil,
                progressSeconds: 33,
                watchedAt: Date(timeIntervalSince1970: 1_735_646_700),
                csrf: "csrf123"
            )
        )
        XCTAssertEqual(step, 4)
    }

    func testFetchHistoryCodeMinus400MapsToNetworkFailed() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/web-interface/history/cursor")
            let json = #"{"code":-400,"message":"请求错误"}"#
            return self.response(request.url!, json: json)
        }

        do {
            _ = try await client.fetchHistory(cursor: nil)
            XCTFail("Expected error")
        } catch let error as BiliClientError {
            switch error {
            case .networkFailed(let message):
                XCTAssertTrue(message.contains("请求错误"))
            default:
                XCTFail("Unexpected error \(error)")
            }
        }
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> DefaultBiliHistoryClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BiliHistoryURLProtocol.self]
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        BiliHistoryURLProtocol.prepare(handler)
        let session = URLSession(configuration: config)

        let fetcher = PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0),
            credentialProvider: {
                BiliCredential(
                    sessdata: "sess",
                    biliJct: "csrf123",
                    dedeUserID: nil,
                    updatedAt: Date()
                )
            }
        )
        return DefaultBiliHistoryClient(
            fetcher: fetcher,
            apiBaseURL: URL(string: "https://api.bilibili.com")!
        )
    }

    private func response(_ url: URL, json: String) -> (HTTPURLResponse, Data) {
        let http = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (http, Data(json.utf8))
    }

    private func bodyString(from request: URLRequest) -> String {
        if let data = request.httpBody, let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard let stream = request.httpBodyStream else {
            return ""
        }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
