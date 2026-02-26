import Foundation
import SwiftUI
import NewBiCore
#if canImport(SwiftData)
import SwiftData
#endif

struct BiliCookieStatus {
    let isConfigured: Bool
    let canWriteHistory: Bool
    let summary: String
}

enum BiliCookieImportError: LocalizedError {
    case emptySessdata
    case invalidSessdata
    case missingBiliJct
    case invalidBiliJct

    var errorDescription: String? {
        switch self {
        case .emptySessdata:
            return "SESSDATA 为空"
        case .invalidSessdata:
            return "SESSDATA 格式无效"
        case .missingBiliJct:
            return "bili_jct 为空"
        case .invalidBiliJct:
            return "bili_jct 格式无效"
        }
    }
}

final class BiliCookieStore {
    private let userDefaults: UserDefaults
    private let cookieStorage: HTTPCookieStorage
    private let credentialStore: BiliCredentialKeychainStore
    private let legacySessdataStore: SessdataKeychainStore

    private let legacySessdataKey = "newbi.bilibili.sessdata"

    init(
        userDefaults: UserDefaults = .standard,
        cookieStorage: HTTPCookieStorage = .shared,
        credentialStore: BiliCredentialKeychainStore,
        legacySessdataStore: SessdataKeychainStore
    ) {
        self.userDefaults = userDefaults
        self.cookieStorage = cookieStorage
        self.credentialStore = credentialStore
        self.legacySessdataStore = legacySessdataStore
    }

    func currentCredential() -> BiliCredential? {
        credentialStore.readCredential()
    }

    func restoreFromPersistedCredential() -> BiliCookieStatus {
        credentialStore.migrateLegacySessdataIfNeeded(legacySessdataStore)
        migrateLegacyUserDefaultsIfNeeded()

        let result = credentialStore.readCredentialResult(logFailures: true)
        switch result {
        case .found(let credential):
            clearBilibiliCookiesFromStorage()
            applyCredentialCookies(credential)
            return makeConfiguredStatus(credential)
        case .notFound:
            clearBilibiliCookiesFromStorage()
            return BiliCookieStatus(
                isConfigured: false,
                canWriteHistory: false,
                summary: "未导入登录态"
            )
        case .failure:
            clearBilibiliCookiesFromStorage()
            return BiliCookieStatus(
                isConfigured: false,
                canWriteHistory: false,
                summary: "读取登录态失败（详见日志）"
            )
        }
    }

    func importManualCredential(sessdataRaw: String, biliJctRaw: String) throws -> BiliCookieStatus {
        let sessdata = try normalizeCookieValue(sessdataRaw, name: "SESSDATA")
        let biliJct = try normalizeBiliJct(biliJctRaw)
        let credential = BiliCredential(
            sessdata: sessdata,
            biliJct: biliJct,
            dedeUserID: nil,
            updatedAt: Date()
        )
        try credentialStore.saveCredential(credential)
        userDefaults.removeObject(forKey: legacySessdataKey)

        clearBilibiliCookiesFromStorage()
        applyCredentialCookies(credential)
        return makeConfiguredStatus(credential)
    }

    func importCredentialFromQR(_ credential: BiliCredential) throws -> BiliCookieStatus {
        let sessdata = try normalizeCookieValue(credential.sessdata, name: "SESSDATA")
        let normalized = BiliCredential(
            sessdata: sessdata,
            biliJct: try normalizeOptionalBiliJct(credential.biliJct),
            dedeUserID: credential.dedeUserID,
            updatedAt: credential.updatedAt
        )
        try credentialStore.saveCredential(normalized)
        userDefaults.removeObject(forKey: legacySessdataKey)

        clearBilibiliCookiesFromStorage()
        applyCredentialCookies(normalized)
        return makeConfiguredStatus(normalized)
    }

    func clearPersistedCookies() -> BiliCookieStatus {
        userDefaults.removeObject(forKey: legacySessdataKey)
        try? credentialStore.deleteCredential()
        try? legacySessdataStore.deleteSessdata()
        clearBilibiliCookiesFromStorage()
        return BiliCookieStatus(
            isConfigured: false,
            canWriteHistory: false,
            summary: "未导入登录态"
        )
    }

    private func migrateLegacyUserDefaultsIfNeeded() {
        guard credentialStore.readCredential() == nil else {
            userDefaults.removeObject(forKey: legacySessdataKey)
            return
        }
        guard let legacySessdata = userDefaults.string(forKey: legacySessdataKey),
              !legacySessdata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        guard let normalized = try? normalizeCookieValue(legacySessdata, name: "SESSDATA") else {
            userDefaults.removeObject(forKey: legacySessdataKey)
            return
        }
        let migrated = BiliCredential(
            sessdata: normalized,
            biliJct: nil,
            dedeUserID: nil,
            updatedAt: Date()
        )
        try? credentialStore.saveCredential(migrated)
        userDefaults.removeObject(forKey: legacySessdataKey)
    }

    private func normalizeCookieValue(_ raw: String, name: String) throws -> String {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            if name.caseInsensitiveCompare("SESSDATA") == .orderedSame {
                throw BiliCookieImportError.emptySessdata
            }
            throw BiliCookieImportError.invalidBiliJct
        }

        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowerName = name.lowercased()
        if input.lowercased().hasPrefix("\(lowerName)=") {
            input = String(input.dropFirst(lowerName.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if input.contains(";") || input.contains("=") {
            if let parsed = extractCookieValue(from: input, cookieName: name) {
                input = parsed
            }
        }

        if input.hasPrefix("\""), input.hasSuffix("\""), input.count >= 2 {
            input.removeFirst()
            input.removeLast()
        }
        if input.hasPrefix("'"), input.hasSuffix("'"), input.count >= 2 {
            input.removeFirst()
            input.removeLast()
        }

        let invalidChars = CharacterSet(charactersIn: ";\n\r")
        guard !input.isEmpty, input.rangeOfCharacter(from: invalidChars) == nil else {
            if name.caseInsensitiveCompare("SESSDATA") == .orderedSame {
                throw BiliCookieImportError.invalidSessdata
            }
            throw BiliCookieImportError.invalidBiliJct
        }
        return input
    }

    private func normalizeBiliJct(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BiliCookieImportError.missingBiliJct
        }
        return try normalizeCookieValue(trimmed, name: "bili_jct")
    }

    private func normalizeOptionalBiliJct(_ raw: String?) throws -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return try normalizeCookieValue(trimmed, name: "bili_jct")
    }

    private func extractCookieValue(from cookieHeader: String, cookieName: String) -> String? {
        let tokens = cookieHeader.components(separatedBy: CharacterSet(charactersIn: ";\n\r"))
        for rawToken in tokens {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let equalIndex = token.firstIndex(of: "=") else {
                continue
            }
            let name = String(token[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(token[token.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.caseInsensitiveCompare(cookieName) == .orderedSame {
                return value
            }
        }
        return nil
    }

    private func applyCredentialCookies(_ credential: BiliCredential) {
        let expiry = Date().addingTimeInterval(180 * 24 * 60 * 60)
        let domains = [
            ".bilibili.com",
            "www.bilibili.com",
            "api.bilibili.com",
            "search.bilibili.com",
            "space.bilibili.com",
            "passport.bilibili.com"
        ]

        for domain in domains {
            setCookie(name: "SESSDATA", value: credential.sessdata, domain: domain, expires: expiry)
            if let biliJct = credential.biliJct, !biliJct.isEmpty {
                setCookie(name: "bili_jct", value: biliJct, domain: domain, expires: expiry)
            }
            if let uid = credential.dedeUserID, !uid.isEmpty {
                setCookie(name: "DedeUserID", value: uid, domain: domain, expires: expiry)
            }
        }
    }

    private func setCookie(name: String, value: String, domain: String, expires: Date) {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
            .expires: expires
        ]
        if let cookie = HTTPCookie(properties: properties) {
            cookieStorage.setCookie(cookie)
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

    private func makeConfiguredStatus(_ credential: BiliCredential) -> BiliCookieStatus {
        let timeText = credential.updatedAt.formatted(date: .abbreviated, time: .shortened)
        if credential.canWriteHistory {
            return BiliCookieStatus(
                isConfigured: true,
                canWriteHistory: true,
                summary: "已登录（双向可用，更新时间：\(timeText)）"
            )
        }
        return BiliCookieStatus(
            isConfigured: true,
            canWriteHistory: false,
            summary: "已登录（只读：缺少 bili_jct，更新时间：\(timeText)）"
        )
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    private static let legacySubscriptionCleanupKey = "newbi.cleanup.legacy-subscription.v1"

    @Published private(set) var bilibiliCookieConfigured = false
    @Published private(set) var bilibiliHistoryWriteEnabled = false
    @Published private(set) var bilibiliCookieStatusText = "未导入登录态"

    let biliClient: any BiliPublicClient
    let biliAuthClient: any BiliAuthClient
    let watchHistoryRepository: any WatchHistoryRepository
    let historySyncCoordinator: any WatchHistorySyncCoordinator
    let playbackItemFactory: any PlaybackItemFactoryProtocol

    private let cookieStore: BiliCookieStore
    private let historySyncEngine: HistorySyncEngine
    private var syncLoopTask: Task<Void, Never>?
    private var appIsActive = true
    #if canImport(SwiftData)
    private var modelContainerBox: Any?
    #endif

    init() {
        let credentialStore = BiliCredentialKeychainStore()
        let legacySessdataStore = SessdataKeychainStore()
        self.cookieStore = BiliCookieStore(
            credentialStore: credentialStore,
            legacySessdataStore: legacySessdataStore
        )
        let credentialProvider: @Sendable () -> BiliCredential? = {
            credentialStore.readCredential()
        }

        self.biliClient = DefaultBiliPublicClient(
            fetcher: PublicWebFetcher(credentialProvider: credentialProvider)
        )
        self.biliAuthClient = DefaultBiliAuthClient(fetcher: PublicWebFetcher())
        self.playbackItemFactory = PlaybackItemFactory()

        let appSupportURL = Self.resolveAppSupportDirectory()
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let fallbackHistoryRepo = FileWatchHistoryRepository(
            fileURL: appSupportURL.appendingPathComponent("history.json")
        )

        let localHistoryRepo: any WatchHistoryRepository
        var subscriptionCleanupModelContext: Any?

        let enableSwiftData = ProcessInfo.processInfo.environment["NEWBI_ENABLE_SWIFTDATA"] == "1"
        if enableSwiftData, #available(iOS 17.0, *) {
            do {
                let container = try NewBiModelContainerFactory.makeContainer()
                self.modelContainerBox = container
                localHistoryRepo = SwiftDataWatchHistoryRepository(modelContext: container.mainContext)
                subscriptionCleanupModelContext = container.mainContext
            } catch {
                localHistoryRepo = fallbackHistoryRepo
            }
        } else {
            localHistoryRepo = fallbackHistoryRepo
        }

        let historyClient = DefaultBiliHistoryClient(
            fetcher: PublicWebFetcher(credentialProvider: credentialProvider)
        )
        let syncEngine = HistorySyncEngine(
            historyClient: historyClient,
            localRepository: localHistoryRepo,
            credentialProvider: credentialProvider,
            metaURL: appSupportURL.appendingPathComponent("history_sync_meta.json")
        )
        self.historySyncEngine = syncEngine
        self.historySyncCoordinator = syncEngine
        self.watchHistoryRepository = SyncingWatchHistoryRepository(
            localRepository: localHistoryRepo,
            syncEngine: syncEngine
        )

        performLegacySubscriptionCleanupIfNeeded(
            appSupportURL: appSupportURL,
            swiftDataModelContext: subscriptionCleanupModelContext
        )

        refreshCookieStatus()
        startSyncLoop()

        Task {
            await syncEngine.triggerStartupSync()
        }
    }

    deinit {
        syncLoopTask?.cancel()
    }

    func importBilibiliCredential(sessdataRaw: String, biliJctRaw: String) throws {
        let status = try cookieStore.importManualCredential(
            sessdataRaw: sessdataRaw,
            biliJctRaw: biliJctRaw
        )
        bilibiliCookieConfigured = status.isConfigured
        bilibiliHistoryWriteEnabled = status.canWriteHistory
        bilibiliCookieStatusText = status.summary

        Task {
            await historySyncEngine.triggerManualSync()
        }
    }

    func importBilibiliCredentialFromQR(_ credential: BiliCredential) throws {
        let status = try cookieStore.importCredentialFromQR(credential)
        bilibiliCookieConfigured = status.isConfigured
        bilibiliHistoryWriteEnabled = status.canWriteHistory
        bilibiliCookieStatusText = status.summary

        Task {
            await historySyncEngine.triggerManualSync()
        }
    }

    func clearBilibiliCookie() {
        let status = cookieStore.clearPersistedCookies()
        bilibiliCookieConfigured = status.isConfigured
        bilibiliHistoryWriteEnabled = status.canWriteHistory
        bilibiliCookieStatusText = status.summary
    }

    func triggerManualHistorySync() async {
        await historySyncEngine.triggerManualSync()
    }

    func notifySceneActive(_ isActive: Bool) {
        appIsActive = isActive
        guard isActive else {
            return
        }
        Task {
            await historySyncEngine.triggerPeriodicSyncIfNeeded()
        }
    }

    private func refreshCookieStatus() {
        let status = cookieStore.restoreFromPersistedCredential()
        bilibiliCookieConfigured = status.isConfigured
        bilibiliHistoryWriteEnabled = status.canWriteHistory
        bilibiliCookieStatusText = status.summary
    }

    private func startSyncLoop() {
        syncLoopTask?.cancel()
        syncLoopTask = Task { @MainActor [weak self] in
            while let self {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    return
                }
                guard self.appIsActive else {
                    continue
                }
                await self.historySyncEngine.triggerPeriodicSyncIfNeeded()
            }
        }
    }

    private func performLegacySubscriptionCleanupIfNeeded(
        appSupportURL: URL,
        swiftDataModelContext: Any?
    ) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.legacySubscriptionCleanupKey) else {
            return
        }

        let subscriptionsFile = appSupportURL.appendingPathComponent("subscriptions.json")
        try? FileManager.default.removeItem(at: subscriptionsFile)

        #if canImport(SwiftData)
        if #available(iOS 17.0, *),
           let swiftDataModelContext = swiftDataModelContext as? ModelContext
        {
            do {
                let entities = try swiftDataModelContext.fetch(FetchDescriptor<SubscriptionEntity>())
                for entity in entities {
                    swiftDataModelContext.delete(entity)
                }
                if !entities.isEmpty {
                    try swiftDataModelContext.save()
                }
            } catch {
                // Best effort cleanup. Existing data does not affect current product flow.
            }
        }
        #endif

        defaults.set(true, forKey: Self.legacySubscriptionCleanupKey)
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
