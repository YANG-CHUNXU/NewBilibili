import Foundation

public struct BiliQRCodeSession: Hashable, Sendable {
    public let qrcodeKey: String
    public let loginURL: URL
    public let expiresAt: Date?

    public init(qrcodeKey: String, loginURL: URL, expiresAt: Date?) {
        self.qrcodeKey = qrcodeKey
        self.loginURL = loginURL
        self.expiresAt = expiresAt
    }
}

public enum BiliQRCodePollState: Hashable, Sendable {
    case waitingScan
    case waitingConfirm
    case confirmed(BiliCredential)
    case expired
}

public protocol BiliAuthClient: Sendable {
    func createQRCodeSession() async throws -> BiliQRCodeSession
    func pollQRCodeStatus(qrcodeKey: String) async throws -> BiliQRCodePollState
}

public final class DefaultBiliAuthClient: BiliAuthClient, @unchecked Sendable {
    private let fetcher: PublicWebFetcher
    private let passportBaseURL: URL

    public init(
        fetcher: PublicWebFetcher = PublicWebFetcher(),
        passportBaseURL: URL = URL(string: "https://passport.bilibili.com")!
    ) {
        self.fetcher = fetcher
        self.passportBaseURL = passportBaseURL
    }

    public func createQRCodeSession() async throws -> BiliQRCodeSession {
        let url = passportBaseURL.appending(path: "/x/passport-login/web/qrcode/generate")
        let json = try await fetcher.fetchJSON(url: url)
        try validateTopLevelResponse(json, source: "二维码生成")

        guard let top = JSONHelpers.dict(json),
              let data = JSONHelpers.dict(top["data"]),
              let key = JSONHelpers.string(data["qrcode_key"]),
              let loginURLText = JSONHelpers.string(data["url"]),
              let loginURL = URL(string: loginURLText)
        else {
            throw BiliClientError.parseFailed("二维码生成返回结构异常")
        }

        let expiresAt: Date?
        if let seconds = JSONHelpers.int(data["expires_in"]) {
            expiresAt = Date().addingTimeInterval(TimeInterval(seconds))
        } else {
            expiresAt = nil
        }

        return BiliQRCodeSession(
            qrcodeKey: key,
            loginURL: loginURL,
            expiresAt: expiresAt
        )
    }

    public func pollQRCodeStatus(qrcodeKey: String) async throws -> BiliQRCodePollState {
        var components = URLComponents(
            url: passportBaseURL.appending(path: "/x/passport-login/web/qrcode/poll"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "qrcode_key", value: qrcodeKey)
        ]
        guard let url = components?.url else {
            throw BiliClientError.invalidInput("二维码轮询参数无效")
        }

        let json = try await fetcher.fetchJSON(url: url)
        try validateTopLevelResponse(json, source: "二维码轮询")
        guard let top = JSONHelpers.dict(json),
              let data = JSONHelpers.dict(top["data"]),
              let pollCode = JSONHelpers.int(data["code"])
        else {
            throw BiliClientError.parseFailed("二维码轮询结构异常")
        }

        switch pollCode {
        case 0:
            let credential = try extractCredential(from: data)
            return .confirmed(credential)
        case 86038:
            return .expired
        case 86090:
            return .waitingConfirm
        case 86101:
            return .waitingScan
        default:
            let message = JSONHelpers.string(data["message"]) ?? "二维码状态未知(\(pollCode))"
            throw BiliClientError.networkFailed(message)
        }
    }

    private func extractCredential(from data: [String: Any]) throws -> BiliCredential {
        var sessdata: String?
        var biliJct: String?
        var dedeUserID: String?

        if let urlText = JSONHelpers.string(data["url"]),
           let components = URLComponents(string: urlText)
        {
            let queryItems = components.percentEncodedQueryItems ?? components.queryItems ?? []
            for item in queryItems {
                guard let value = item.value, !value.isEmpty else {
                    continue
                }
                switch item.name.lowercased() {
                case "sessdata":
                    sessdata = value
                case "bili_jct":
                    biliJct = value
                case "dedeuserid":
                    dedeUserID = value
                default:
                    break
                }
            }
        }

        if let cookieInfo = JSONHelpers.dict(data["cookie_info"]),
           let cookies = JSONHelpers.array(cookieInfo["cookies"])
        {
            for cookieAny in cookies {
                guard let cookie = JSONHelpers.dict(cookieAny),
                      let name = JSONHelpers.string(cookie["name"]),
                      let value = JSONHelpers.string(cookie["value"])
                else {
                    continue
                }
                switch name.lowercased() {
                case "sessdata":
                    sessdata = value
                case "bili_jct":
                    biliJct = value
                case "dedeuserid":
                    dedeUserID = value
                default:
                    break
                }
            }
        }

        guard let sessdata, !sessdata.isEmpty else {
            throw BiliClientError.parseFailed("登录成功但未返回 SESSDATA")
        }

        return BiliCredential(
            sessdata: sessdata,
            biliJct: biliJct,
            dedeUserID: dedeUserID,
            updatedAt: Date()
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
            case -352, -412, -509:
                throw BiliClientError.rateLimited
            default:
                throw BiliClientError.networkFailed("\(source)接口返回异常(code=\(code))：\(message)")
            }
        }
    }
}
