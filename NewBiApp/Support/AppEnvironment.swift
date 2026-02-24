import Foundation
import SwiftUI
import NewBiCore
#if canImport(SwiftData)
import SwiftData
#endif

@MainActor
final class AppEnvironment: ObservableObject {
    let biliClient: any BiliPublicClient
    let subscriptionRepository: any SubscriptionRepository
    let watchHistoryRepository: any WatchHistoryRepository
    #if canImport(SwiftData)
    private var modelContainerBox: Any?
    #endif

    init() {
        self.biliClient = DefaultBiliPublicClient()

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
                return
            } catch {
                self.subscriptionRepository = fallbackSubscriptionRepo
                self.watchHistoryRepository = fallbackHistoryRepo
                return
            }
        }

        self.subscriptionRepository = fallbackSubscriptionRepo
        self.watchHistoryRepository = fallbackHistoryRepo
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
