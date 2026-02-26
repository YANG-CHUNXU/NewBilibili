import Foundation
import XCTest
@testable import NewBiCore

private final class BiliAuthURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
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
        lock.unlock()
    }
}

final class BiliAuthClientTests: XCTestCase {
    func testGenerateQRCodeParsesSession() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/passport-login/web/qrcode/generate")
            let json = """
            {"code":0,"data":{"url":"https://passport.bilibili.com/h5-login?key=abc","qrcode_key":"key-123","expires_in":180}}
            """
            return self.response(request.url!, json: json)
        }

        let session = try await client.createQRCodeSession()
        XCTAssertEqual(session.qrcodeKey, "key-123")
        XCTAssertEqual(session.loginURL.absoluteString, "https://passport.bilibili.com/h5-login?key=abc")
        XCTAssertNotNil(session.expiresAt)
    }

    func testPollReturnsWaitingStates() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/passport-login/web/qrcode/poll")
            let json = """
            {"code":0,"data":{"code":86090,"message":"waiting_confirm"}}
            """
            return self.response(request.url!, json: json)
        }

        let state = try await client.pollQRCodeStatus(qrcodeKey: "k1")
        XCTAssertEqual(state, .waitingConfirm)
    }

    func testPollExtractsCredentialFromCookieInfo() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/passport-login/web/qrcode/poll")
            let json = """
            {"code":0,"data":{"code":0,"url":"https://www.bilibili.com/","cookie_info":{"cookies":[{"name":"SESSDATA","value":"sess-1"},{"name":"bili_jct","value":"csrf-1"},{"name":"DedeUserID","value":"10086"}]}}}
            """
            return self.response(request.url!, json: json)
        }

        let state = try await client.pollQRCodeStatus(qrcodeKey: "k2")
        guard case .confirmed(let credential) = state else {
            XCTFail("Expected confirmed state")
            return
        }
        XCTAssertEqual(credential.sessdata, "sess-1")
        XCTAssertEqual(credential.biliJct, "csrf-1")
        XCTAssertEqual(credential.dedeUserID, "10086")
    }

    func testPollPreservesPercentEncodedCredentialValuesFromURL() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/x/passport-login/web/qrcode/poll")
            let json = """
            {"code":0,"data":{"code":0,"url":"https://passport.bilibili.com/h5-login/success?SESSDATA=sess%2Cencoded%2Cvalue&bili_jct=csrf%2Btoken&DedeUserID=10086"}}
            """
            return self.response(request.url!, json: json)
        }

        let state = try await client.pollQRCodeStatus(qrcodeKey: "k3")
        guard case .confirmed(let credential) = state else {
            XCTFail("Expected confirmed state")
            return
        }
        XCTAssertEqual(credential.sessdata, "sess%2Cencoded%2Cvalue")
        XCTAssertEqual(credential.biliJct, "csrf%2Btoken")
        XCTAssertEqual(credential.dedeUserID, "10086")
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> DefaultBiliAuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BiliAuthURLProtocol.self]
        BiliAuthURLProtocol.prepare(handler)
        let session = URLSession(configuration: config)
        let fetcher = PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0)
        )
        return DefaultBiliAuthClient(
            fetcher: fetcher,
            passportBaseURL: URL(string: "https://passport.bilibili.com")!
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
}
