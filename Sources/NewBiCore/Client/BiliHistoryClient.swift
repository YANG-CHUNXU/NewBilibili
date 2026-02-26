import Foundation

public protocol BiliHistoryClient: Sendable {
    func fetchHistory(cursor: HistoryCursor?) async throws -> HistoryFetchResult
    func reportProgress(_ report: HistoryProgressReport) async throws
    func deleteHistory(key: RemoteHistoryKey, csrf: String) async throws
}

public final class DefaultBiliHistoryClient: BiliHistoryClient, @unchecked Sendable {
    private let fetcher: PublicWebFetcher
    private let apiBaseURL: URL
    private let reportIdentifierCache = HistoryReportIdentifierCache()

    public init(
        fetcher: PublicWebFetcher = PublicWebFetcher(),
        apiBaseURL: URL = URL(string: "https://api.bilibili.com")!
    ) {
        self.fetcher = fetcher
        self.apiBaseURL = apiBaseURL
    }

    public func fetchHistory(cursor: HistoryCursor?) async throws -> HistoryFetchResult {
        var components = URLComponents(
            url: apiBaseURL.appending(path: "/x/web-interface/history/cursor"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "ps", value: "30")
        ]
        if let cursor {
            if let max = cursor.max {
                queryItems.append(URLQueryItem(name: "max", value: String(max)))
            }
            if let viewAt = cursor.viewAt {
                queryItems.append(URLQueryItem(name: "view_at", value: String(viewAt)))
            }
            let business = cursor.business?.trimmingCharacters(in: .whitespacesAndNewlines)
            queryItems.append(URLQueryItem(name: "business", value: (business?.isEmpty == false) ? business : "archive"))
        } else {
            // Some gateway nodes return code=-400 when initial cursor fields are omitted.
            queryItems.append(URLQueryItem(name: "max", value: "0"))
            queryItems.append(URLQueryItem(name: "view_at", value: "0"))
            queryItems.append(URLQueryItem(name: "business", value: "archive"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("历史拉取参数无效")
        }

        let json = try await fetcher.fetchJSON(url: url)
        return try parseHistoryFetchResult(from: json)
    }

    public func reportProgress(_ report: HistoryProgressReport) async throws {
        guard !report.csrf.isEmpty else {
            throw BiliClientError.authRequired("缺少 bili_jct")
        }

        let url = apiBaseURL.appending(path: "/x/v2/history/report")
        var bodyFields = makeReportBodyFields(report: report)
        if let cached = await reportIdentifierCache.resolve(bvid: report.bvid) {
            bodyFields["aid"] = String(cached.aid)
            if report.cid == nil, let cid = cached.cid {
                bodyFields["cid"] = String(cid)
            }
        }

        let json = try await fetcher.fetchJSON(
            url: url,
            method: "POST",
            formBodyFields: bodyFields,
            additionalHeaders: [:]
        )
        if topLevelCode(from: json) == -400 {
            let resolved = try await resolveReportIdentifiers(bvid: report.bvid)
            await reportIdentifierCache.store(bvid: report.bvid, identifiers: resolved)

            var retryBody = makeReportBodyFields(report: report)
            retryBody["aid"] = String(resolved.aid)
            if report.cid == nil, let cid = resolved.cid {
                retryBody["cid"] = String(cid)
            }
            let retryJSON = try await fetcher.fetchJSON(
                url: url,
                method: "POST",
                formBodyFields: retryBody,
                additionalHeaders: [:]
            )
            if topLevelCode(from: retryJSON) == -400 {
                let cid = report.cid ?? resolved.cid
                guard let cid else {
                    throw BiliClientError.invalidInput("历史上报缺少 cid")
                }
                let minimalBody = makeMinimalReportBodyFields(
                    report: report,
                    aid: resolved.aid,
                    cid: cid
                )
                let minimalJSON = try await fetcher.fetchJSON(
                    url: url,
                    method: "POST",
                    formBodyFields: minimalBody,
                    additionalHeaders: [:]
                )
                try validateTopLevelResponse(minimalJSON, source: "历史上报")
                return
            }
            try validateTopLevelResponse(retryJSON, source: "历史上报")
            return
        }
        try validateTopLevelResponse(json, source: "历史上报")
    }

    private func makeReportBodyFields(report: HistoryProgressReport) -> [String: String] {
        var bodyFields: [String: String] = [
            "csrf": report.csrf,
            "csrf_token": report.csrf,
            "bvid": report.bvid,
            "progress": String(Int(max(report.progressSeconds, 0))),
            "platform": "ios"
        ]
        if let cid = report.cid {
            bodyFields["cid"] = String(cid)
        }
        bodyFields["view_at"] = String(Int(report.watchedAt.timeIntervalSince1970))
        return bodyFields
    }

    private func makeMinimalReportBodyFields(
        report: HistoryProgressReport,
        aid: Int,
        cid: Int
    ) -> [String: String] {
        [
            "csrf": report.csrf,
            "csrf_token": report.csrf,
            "aid": String(aid),
            "cid": String(cid),
            "progress": String(Int(max(report.progressSeconds, 0))),
            "view_at": String(Int(report.watchedAt.timeIntervalSince1970))
        ]
    }

    private func resolveReportIdentifiers(bvid: String) async throws -> HistoryReportIdentifiers {
        var components = URLComponents(
            url: apiBaseURL.appending(path: "/x/web-interface/view"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "bvid", value: bvid)
        ]
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("稿件查询参数无效")
        }

        let json = try await fetcher.fetchJSON(url: url)
        try validateTopLevelResponse(json, source: "稿件查询")
        guard let top = JSONHelpers.dict(json),
              let data = JSONHelpers.dict(top["data"])
        else {
            throw BiliClientError.parseFailed("稿件查询返回缺少 data")
        }

        guard let aid = JSONHelpers.int(data["aid"]) else {
            throw BiliClientError.parseFailed("稿件查询返回缺少 aid")
        }
        let cid = JSONHelpers.int(data["cid"]) ??
            JSONHelpers.int(JSONHelpers.array(data["pages"])?.compactMap(JSONHelpers.dict).first?["cid"])
        return HistoryReportIdentifiers(aid: aid, cid: cid)
    }

    private func topLevelCode(from root: Any) -> Int? {
        guard let top = JSONHelpers.dict(root) else {
            return nil
        }
        return JSONHelpers.int(top["code"])
    }

    public func deleteHistory(key: RemoteHistoryKey, csrf: String) async throws {
        guard !csrf.isEmpty else {
            throw BiliClientError.authRequired("缺少 bili_jct")
        }
        let url = apiBaseURL.appending(path: "/x/v2/history/delete")
        let bodyFields: [String: String] = [
            "csrf": csrf,
            "csrf_token": csrf,
            "bvid": key.bvid
        ]
        let json = try await fetcher.fetchJSON(
            url: url,
            method: "POST",
            formBodyFields: bodyFields,
            additionalHeaders: [:]
        )
        try validateTopLevelResponse(json, source: "历史删除")
    }

    private func parseHistoryFetchResult(from root: Any) throws -> HistoryFetchResult {
        try validateTopLevelResponse(root, source: "历史拉取")
        guard let top = JSONHelpers.dict(root),
              let data = JSONHelpers.dict(top["data"])
        else {
            throw BiliClientError.parseFailed("历史返回缺少 data")
        }

        let listAny = data["list"] ?? data["items"] ?? []
        guard let list = JSONHelpers.array(listAny) else {
            throw BiliClientError.parseFailed("历史列表格式错误")
        }

        var items: [RemoteHistoryItem] = []
        items.reserveCapacity(list.count)
        for rawItem in list {
            guard let dict = JSONHelpers.dict(rawItem),
                  let bvid = JSONHelpers.string(dict["bvid"]),
                  !bvid.isEmpty
            else {
                continue
            }

            let title =
                JSONHelpers.string(dict["title"]) ??
                JSONHelpers.string(JSONHelpers.dict(dict["history"])?["title"]) ??
                ""
            let progress =
                JSONHelpers.double(dict["progress"]) ??
                JSONHelpers.double(JSONHelpers.dict(dict["history"])?["progress"]) ??
                0
            let watchedAt =
                JSONHelpers.dateFromTimestamp(dict["view_at"]) ??
                JSONHelpers.dateFromTimestamp(dict["watched_at"]) ??
                JSONHelpers.dateFromTimestamp(JSONHelpers.dict(dict["history"])?["view_at"]) ??
                Date()
            let cid =
                JSONHelpers.int(dict["cid"]) ??
                JSONHelpers.int(JSONHelpers.dict(dict["history"])?["cid"])
            let duration =
                JSONHelpers.double(dict["duration"]) ??
                JSONHelpers.double(JSONHelpers.dict(dict["history"])?["duration"])

            items.append(
                RemoteHistoryItem(
                    key: RemoteHistoryKey(bvid: bvid),
                    bvid: bvid,
                    title: title,
                    progressSeconds: progress,
                    watchedAt: watchedAt,
                    cid: cid,
                    durationSeconds: duration
                )
            )
        }

        let cursorDict =
            JSONHelpers.dict(data["cursor"]) ??
            JSONHelpers.dict(data["page"]) ??
            [:]
        let nextCursor = HistoryCursor(
            max: JSONHelpers.int(cursorDict["max"]),
            viewAt: JSONHelpers.int(cursorDict["view_at"]),
            business: JSONHelpers.string(cursorDict["business"])
        )
        let hasMore =
            (JSONHelpers.bool(cursorDict["has_more"]) ?? false) ||
            (JSONHelpers.int(cursorDict["max"]) ?? 0 > 0 && !items.isEmpty)

        return HistoryFetchResult(
            items: items,
            nextCursor: nextCursor.max == nil && nextCursor.viewAt == nil && nextCursor.business == nil ? nil : nextCursor,
            hasMore: hasMore
        )
    }

    private func validateTopLevelResponse(_ root: Any, source: String) throws {
        guard let top = JSONHelpers.dict(root),
              let code = JSONHelpers.int(top["code"])
        else {
            throw BiliClientError.parseFailed("\(source)返回缺少 code")
        }

        guard code == 0 else {
            let message = JSONHelpers.string(top["message"]) ?? JSONHelpers.string(top["msg"]) ?? "未知错误"
            switch code {
            case -101, -111, -401:
                throw BiliClientError.authRequired(message)
            case -352, -412, -509:
                throw BiliClientError.rateLimited
            default:
                throw BiliClientError.networkFailed("\(source)接口返回异常(code=\(code))：\(message)")
            }
        }
    }
}

private struct HistoryReportIdentifiers: Hashable, Sendable {
    let aid: Int
    let cid: Int?
}

private actor HistoryReportIdentifierCache {
    private var values: [String: HistoryReportIdentifiers] = [:]

    func resolve(bvid: String) -> HistoryReportIdentifiers? {
        values[bvid]
    }

    func store(bvid: String, identifiers: HistoryReportIdentifiers) {
        values[bvid] = identifiers
    }
}

private extension JSONHelpers {
    static func bool(_ any: Any?) -> Bool? {
        if let value = any as? Bool {
            return value
        }
        if let value = any as? NSNumber {
            return value.boolValue
        }
        if let value = any as? String {
            switch value.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
