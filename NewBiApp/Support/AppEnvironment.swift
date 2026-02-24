import Foundation
import SwiftUI
import NewBiCore
#if canImport(SwiftData)
import SwiftData
#endif

struct BiliCookieStatus {
    let isConfigured: Bool
    let summary: String
}

enum BiliCookieImportError: LocalizedError {
    case emptyInput
    case invalidSessdata

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "SESSDATA 为空"
        case .invalidSessdata:
            return "SESSDATA 格式无效"
        }
    }
}

final class BiliCookieStore {
    private let userDefaults: UserDefaults
    private let cookieStorage: HTTPCookieStorage

    private let sessdataKey = "newbi.bilibili.sessdata"
    private let updatedAtKey = "newbi.bilibili.cookie.updatedAt"

    init(
        userDefaults: UserDefaults = .standard,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.userDefaults = userDefaults
        self.cookieStorage = cookieStorage
    }

    func restoreFromPersistedSessdata() -> BiliCookieStatus {
        guard let sessdata = userDefaults.string(forKey: sessdataKey),
              !sessdata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return BiliCookieStatus(isConfigured: false, summary: "未导入 SESSDATA")
        }

        clearBilibiliCookiesFromStorage()
        applySessdataCookie(sessdata)
        let updatedAt = userDefaults.object(forKey: updatedAtKey) as? Date
        return makeConfiguredStatus(updatedAt: updatedAt)
    }

    func importSessdata(_ raw: String) throws -> BiliCookieStatus {
        let sessdata = try normalizeSessdata(raw)
        clearBilibiliCookiesFromStorage()
        applySessdataCookie(sessdata)

        userDefaults.set(sessdata, forKey: sessdataKey)
        let now = Date()
        userDefaults.set(now, forKey: updatedAtKey)
        return makeConfiguredStatus(updatedAt: now)
    }

    func clearPersistedCookies() -> BiliCookieStatus {
        userDefaults.removeObject(forKey: sessdataKey)
        userDefaults.removeObject(forKey: updatedAtKey)
        clearBilibiliCookiesFromStorage()
        return BiliCookieStatus(isConfigured: false, summary: "未导入 SESSDATA")
    }

    private func normalizeSessdata(_ raw: String) throws -> String {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw BiliCookieImportError.emptyInput
        }

        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.lowercased().hasPrefix("sessdata=") {
            input = String(input.dropFirst("sessdata=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if input.contains(";") || input.contains("=") {
            let tokens = input.components(separatedBy: CharacterSet(charactersIn: ";\n\r"))
            var found: String?
            for rawToken in tokens {
                let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else {
                    continue
                }
                guard let equalIndex = token.firstIndex(of: "=") else {
                    continue
                }

                let name = String(token[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(token[token.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.caseInsensitiveCompare("SESSDATA") == .orderedSame {
                    found = value
                    break
                }
            }

            if let found {
                input = found
            }
        }

        input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("\""), input.hasSuffix("\""), input.count >= 2 {
            input.removeFirst()
            input.removeLast()
        }
        if input.hasPrefix("'"), input.hasSuffix("'"), input.count >= 2 {
            input.removeFirst()
            input.removeLast()
        }

        let invalidChars = CharacterSet(charactersIn: ";\n\r")
        if input.isEmpty || input.rangeOfCharacter(from: invalidChars) != nil {
            throw BiliCookieImportError.invalidSessdata
        }

        return input
    }

    private func applySessdataCookie(_ sessdata: String) {
        let expiry = Date().addingTimeInterval(180 * 24 * 60 * 60)
        let domains = [
            ".bilibili.com",
            "www.bilibili.com",
            "api.bilibili.com",
            "search.bilibili.com",
            "space.bilibili.com"
        ]

        for domain in domains {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: "/",
                .name: "SESSDATA",
                .value: sessdata,
                .secure: "TRUE",
                .expires: expiry
            ]

            if let cookie = HTTPCookie(properties: properties) {
                cookieStorage.setCookie(cookie)
            }
        }
    }

    private func clearBilibiliCookiesFromStorage() {
        guard let cookies = cookieStorage.cookies else {
            return
        }

        for cookie in cookies where cookie.domain.localizedCaseInsensitiveContains("bilibili.com") {
            cookieStorage.deleteCookie(cookie)
        }
    }

    private func makeConfiguredStatus(updatedAt: Date?) -> BiliCookieStatus {
        let timeText: String
        if let updatedAt {
            timeText = updatedAt.formatted(date: .abbreviated, time: .shortened)
        } else {
            timeText = "未知时间"
        }
        return BiliCookieStatus(
            isConfigured: true,
            summary: "已导入 SESSDATA（更新时间：\(timeText)）"
        )
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var bilibiliCookieConfigured = false
    @Published private(set) var bilibiliCookieStatusText = "未导入 SESSDATA"

    let biliClient: any BiliPublicClient
    let subscriptionRepository: any SubscriptionRepository
    let watchHistoryRepository: any WatchHistoryRepository
    let playbackItemFactory: any PlaybackItemFactoryProtocol
    private let cookieStore: BiliCookieStore
    #if canImport(SwiftData)
    private var modelContainerBox: Any?
    #endif

    init() {
        self.cookieStore = BiliCookieStore()
        self.biliClient = DefaultBiliPublicClient()
        self.playbackItemFactory = PlaybackItemFactory()

        let appSupportURL = Self.resolveAppSupportDirectory()
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let fallbackSubscriptionRepo = FileSubscriptionRepository(
            fileURL: appSupportURL.appendingPathComponent("subscriptions.json")
        )
        let fallbackHistoryRepo = FileWatchHistoryRepository(
            fileURL: appSupportURL.appendingPathComponent("history.json")
        )

        // Default to file repositories for launch stability on beta systems.
        // To opt-in SwiftData, set NEWBI_ENABLE_SWIFTDATA=1 in scheme env.
        let enableSwiftData = ProcessInfo.processInfo.environment["NEWBI_ENABLE_SWIFTDATA"] == "1"
        if enableSwiftData, #available(iOS 17.0, *) {
            do {
                let container = try NewBiModelContainerFactory.makeContainer()
                self.modelContainerBox = container
                self.subscriptionRepository = SwiftDataSubscriptionRepository(modelContext: container.mainContext)
                self.watchHistoryRepository = SwiftDataWatchHistoryRepository(modelContext: container.mainContext)
                refreshCookieStatus()
                return
            } catch {
                self.subscriptionRepository = fallbackSubscriptionRepo
                self.watchHistoryRepository = fallbackHistoryRepo
                refreshCookieStatus()
                return
            }
        }

        self.subscriptionRepository = fallbackSubscriptionRepo
        self.watchHistoryRepository = fallbackHistoryRepo
        refreshCookieStatus()
    }

    func importBilibiliSessdata(_ raw: String) throws {
        let status = try cookieStore.importSessdata(raw)
        bilibiliCookieConfigured = status.isConfigured
        bilibiliCookieStatusText = status.summary
    }

    func clearBilibiliCookie() {
        let status = cookieStore.clearPersistedCookies()
        bilibiliCookieConfigured = status.isConfigured
        bilibiliCookieStatusText = status.summary
    }

    private func refreshCookieStatus() {
        let status = cookieStore.restoreFromPersistedSessdata()
        bilibiliCookieConfigured = status.isConfigured
        bilibiliCookieStatusText = status.summary
    }

    private static func resolveAppSupportDirectory() -> URL {
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("NewBi", isDirectory: true)
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("NewBi", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("NewBi", isDirectory: true)
    }
}
