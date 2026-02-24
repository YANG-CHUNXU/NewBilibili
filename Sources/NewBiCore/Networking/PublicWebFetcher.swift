import Foundation

public final class PublicWebFetcher: @unchecked Sendable {
    private let session: URLSession
    private let scheduler: RequestScheduler
    private let warmupGate = WarmupGate()
    private let sessdataDefaultsKey = "newbi.bilibili.sessdata"
    private let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    public init() {
        self.session = Self.makeDefaultSession()
        self.scheduler = RequestScheduler()
    }

    public init(session: URLSession, scheduler: RequestScheduler = RequestScheduler()) {
        self.session = session
        self.scheduler = scheduler
    }

    public func fetchHTML(url: URL) async throws -> String {
        let data = try await fetchData(
            url: url,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func fetchJSON(url: URL) async throws -> Any {
        try await fetchJSON(url: url, additionalHeaders: [:])
    }

    public func fetchJSON(url: URL, additionalHeaders: [String: String]) async throws -> Any {
        let data = try await fetchData(
            url: url,
            accept: "application/json,text/plain,*/*",
            additionalHeaders: additionalHeaders
        )
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliClientError.parseFailed("JSON 解析失败")
        }
    }

    public func primeBilibiliCookiesIfNeeded() async {
        guard await warmupGate.shouldWarmup(minInterval: 300) else {
            return
        }

        guard let url = URL(string: "https://www.bilibili.com") else {
            return
        }

        _ = try? await fetchData(
            url: url,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        )
        await warmupGate.markWarmup()
    }

    private func fetchData(
        url: URL,
        accept: String,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let host = url.host?.lowercased() else {
            throw BiliClientError.invalidInput("URL 缺少 host")
        }

        await scheduler.acquire(host: host)
        defer {
            Task { await scheduler.release(host: host) }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        if let sessdata = normalizedSessdataFromDefaults() {
            request.setValue("SESSDATA=\(sessdata)", forHTTPHeaderField: "Cookie")
        }
        for (field, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw BiliClientError.networkFailed("无效响应")
                }

                if http.statusCode == 412 || http.statusCode == 429 {
                    throw BiliClientError.rateLimited
                }

                if (200...299).contains(http.statusCode) {
                    return data
                }

                if (500...599).contains(http.statusCode), attempt < 2 {
                    try? await Task.sleep(nanoseconds: retryDelayNs(attempt: attempt))
                    continue
                }

                throw BiliClientError.networkFailed("HTTP \(http.statusCode)")
            } catch {
                lastError = error
                if shouldRetry(error: error), attempt < 2 {
                    try? await Task.sleep(nanoseconds: retryDelayNs(attempt: attempt))
                    continue
                }
                throw mapNetworkError(error)
            }
        }

        throw mapNetworkError(lastError ?? URLError(.unknown))
    }

    private func shouldRetry(error: Error) -> Bool {
        if error is BiliClientError {
            return false
        }
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func mapNetworkError(_ error: Error) -> BiliClientError {
        if let known = error as? BiliClientError {
            return known
        }
        if let urlError = error as? URLError {
            return .networkFailed("URLError(\(urlError.code.rawValue)): \(urlError.localizedDescription)")
        }
        return .networkFailed(error.localizedDescription)
    }

    private func retryDelayNs(attempt: Int) -> UInt64 {
        // 0.5s, 1.0s, ...
        UInt64((attempt + 1) * 500_000_000)
    }

    private func normalizedSessdataFromDefaults() -> String? {
        guard var raw = UserDefaults.standard.string(forKey: sessdataDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        if raw.lowercased().hasPrefix("sessdata=") {
            raw = String(raw.dropFirst("sessdata=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let invalidChars = CharacterSet(charactersIn: ";\n\r")
        guard !raw.isEmpty, raw.rangeOfCharacter(from: invalidChars) == nil else {
            return nil
        }

        return raw
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 2
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config)
    }
}

private actor WarmupGate {
    private var lastWarmupAt: Date?

    func shouldWarmup(minInterval: TimeInterval) -> Bool {
        guard let lastWarmupAt else {
            return true
        }
        return Date().timeIntervalSince(lastWarmupAt) >= minInterval
    }

    func markWarmup() {
        lastWarmupAt = Date()
    }
}
