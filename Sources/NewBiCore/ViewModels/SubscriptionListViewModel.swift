import Foundation
import Combine

@MainActor
public final class SubscriptionListViewModel: ObservableObject {
    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var watchHistory: [WatchHistoryRecord] = []
    @Published public var newSubscriptionInput: String = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let subscriptionRepository: any SubscriptionRepository
    private let watchHistoryRepository: any WatchHistoryRepository

    public init(
        subscriptionRepository: any SubscriptionRepository,
        watchHistoryRepository: any WatchHistoryRepository
    ) {
        self.subscriptionRepository = subscriptionRepository
        self.watchHistoryRepository = watchHistoryRepository
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
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
