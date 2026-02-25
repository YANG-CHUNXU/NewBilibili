import Foundation
import XCTest
@testable import NewBiCore

private final class CookieCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private nonisolated(unsafe) static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequest = request
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
        capturedRequest = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    static func reset() {
        lock.lock()
        requestHandler = nil
        capturedRequest = nil
        lock.unlock()
    }
}

final class PublicWebFetcherSessdataTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CookieCaptureURLProtocol.reset()
    }

    override func tearDown() {
        CookieCaptureURLProtocol.reset()
        super.tearDown()
    }

    func testInjectsSessdataFromProvider() async throws {
        let (fetcher, _) = makeFetcher(sessdataProvider: { "persisted-sessdata" })
        primeResponse()

        _ = try await fetcher.fetchJSON(url: URL(string: "https://api.bilibili.com/x/test")!)

        let cookieHeader = CookieCaptureURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookieHeader.contains("SESSDATA=persisted-sessdata"))
    }

    func testDoesNotInjectWhenProviderReturnsInvalidValue() async throws {
        let (fetcher, _) = makeFetcher(sessdataProvider: { "bad;value" })
        primeResponse()

        _ = try await fetcher.fetchJSON(url: URL(string: "https://api.bilibili.com/x/test")!)

        let cookieHeader = CookieCaptureURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookieHeader.localizedCaseInsensitiveContains("SESSDATA="))
    }

    func testDoesNotInjectWhenProviderIsMissing() async throws {
        let (fetcher, _) = makeFetcher()
        primeResponse()

        _ = try await fetcher.fetchJSON(url: URL(string: "https://api.bilibili.com/x/test")!)

        let cookieHeader = CookieCaptureURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookieHeader.localizedCaseInsensitiveContains("SESSDATA="))
    }

    func testInjectingSessdataDoesNotAffectAdditionalHeaders() async throws {
        let (fetcher, _) = makeFetcher(sessdataProvider: { "persisted-sessdata" })
        primeResponse()

        _ = try await fetcher.fetchJSON(
            url: URL(string: "https://api.bilibili.com/x/test")!,
            additionalHeaders: [
                "X-NewBi-Trace": "trace-123"
            ]
        )

        let request = CookieCaptureURLProtocol.lastRequest()
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-NewBi-Trace"), "trace-123")
        let cookieHeader = request?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookieHeader.contains("SESSDATA=persisted-sessdata"))
    }

    func testDoesNotInjectToNonBilibiliHost() async throws {
        let (fetcher, _) = makeFetcher(sessdataProvider: { "persisted-sessdata" })
        primeResponse()

        _ = try await fetcher.fetchJSON(url: URL(string: "https://example.com/x/test")!)

        let cookieHeader = CookieCaptureURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(cookieHeader.localizedCaseInsensitiveContains("SESSDATA="))
    }

    private func makeFetcher(
        sessdataProvider: (@Sendable () -> String?)? = nil
    ) -> (PublicWebFetcher, HTTPCookieStorage) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CookieCaptureURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        if configuration.httpCookieStorage == nil {
            configuration.httpCookieStorage = .shared
        }

        let cookieStorage = configuration.httpCookieStorage ?? .shared
        clearCookies(in: cookieStorage)
        let session = URLSession(configuration: configuration)
        let fetcher = PublicWebFetcher(
            session: session,
            scheduler: RequestScheduler(maxConcurrentPerHost: 1, minIntervalMs: 0),
            sessdataProvider: sessdataProvider
        )
        return (fetcher, cookieStorage)
    }

    private func primeResponse() {
        CookieCaptureURLProtocol.prepare { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
    }

    private func clearCookies(in cookieStorage: HTTPCookieStorage) {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }
}
