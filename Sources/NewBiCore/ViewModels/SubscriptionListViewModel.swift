import Foundation
import Combine

@MainActor
public final class SubscriptionListViewModel: ObservableObject {
    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var watchHistory: [WatchHistoryRecord] = []
    @Published public private(set) var watchHistorySyncStatus: [String: HistoryItemSyncStatus] = [:]
    @Published public private(set) var historySyncOverview = HistorySyncOverview(
        canWrite: false,
        isAuthRequired: false,
        pendingUploadCount: 0,
        pendingDeleteCount: 0,
        lastSyncAt: nil,
        nextRetryAt: nil,
        statusMessage: nil
    )
    @Published public var newSubscriptionInput: String = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let subscriptionRepository: any SubscriptionRepository
    private let watchHistoryRepository: any WatchHistoryRepository
    private let historySyncCoordinator: (any WatchHistorySyncCoordinator)?

    public init(
        subscriptionRepository: any SubscriptionRepository,
        watchHistoryRepository: any WatchHistoryRepository,
        historySyncCoordinator: (any WatchHistorySyncCoordinator)? = nil
    ) {
        self.subscriptionRepository = subscriptionRepository
        self.watchHistoryRepository = watchHistoryRepository
        self.historySyncCoordinator = historySyncCoordinator
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            async let subscriptionsTask = subscriptionRepository.list()
            async let historyTask = watchHistoryRepository.list()
            subscriptions = try await subscriptionsTask
            watchHistory = try await historyTask
            await refreshSyncState()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func addSubscription() async {
        let input = newSubscriptionInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = BiliClientError.invalidInput("请输入 UID 或主页链接").errorDescription
            return
        }

        do {
            _ = try await subscriptionRepository.add(input: input)
            newSubscriptionInput = ""
            subscriptions = try await subscriptionRepository.list()
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func removeSubscription(at offsets: IndexSet) async {
        let ids = offsets.map { subscriptions[$0].id }
        do {
            for id in ids {
                try await subscriptionRepository.remove(id: id)
            }
            subscriptions = try await subscriptionRepository.list()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func clearHistory() async {
        do {
            try await watchHistoryRepository.clear()
            watchHistory = []
            watchHistorySyncStatus = [:]
            await refreshSyncState()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func triggerManualHistorySync() async {
        guard let historySyncCoordinator else {
            return
        }
        await historySyncCoordinator.triggerManualSync()
        await load()
    }

    public func syncLabel(for bvid: String) -> String {
        let status = watchHistorySyncStatus[bvid] ?? .localOnly
        switch status {
        case .localOnly:
            return "本地"
        case .remote:
            return "云端"
        case .synced:
            return "已同步"
        case .pendingUpload:
            return "待上传"
        case .pendingDelete:
            return "待删除"
        case .failed:
            return "失败"
        }
    }

    private func refreshSyncState() async {
        guard let historySyncCoordinator else {
            return
        }
        historySyncOverview = await historySyncCoordinator.syncOverview()
        var map: [String: HistoryItemSyncStatus] = [:]
        for item in watchHistory {
            map[item.bvid] = await historySyncCoordinator.syncStatus(for: item.bvid)
        }
        watchHistorySyncStatus = map
    }
}
