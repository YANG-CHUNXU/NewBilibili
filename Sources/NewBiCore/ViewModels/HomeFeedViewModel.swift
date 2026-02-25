import Foundation
import Combine

@MainActor
public final class HomeFeedViewModel: ObservableObject {
    @Published public private(set) var videos: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let automaticReloadCooldown: TimeInterval
    private let maxConcurrentSubscriptionFetches: Int
    private let subscriptionRepository: any SubscriptionRepository
    private let biliClient: any BiliPublicClient
    private var lastLoadAt: Date?
    private var didHitRateLimit = false

    public init(
        subscriptionRepository: any SubscriptionRepository,
        biliClient: any BiliPublicClient,
        automaticReloadCooldown: TimeInterval = 30,
        maxConcurrentSubscriptionFetches: Int = 2
    ) {
        self.subscriptionRepository = subscriptionRepository
        self.biliClient = biliClient
        self.automaticReloadCooldown = max(0, automaticReloadCooldown)
        self.maxConcurrentSubscriptionFetches = max(1, maxConcurrentSubscriptionFetches)
    }

    public func load(force: Bool = false) async {
        if isLoading {
            return
        }
        if !force,
           let lastLoadAt,
           Date().timeIntervalSince(lastLoadAt) < automaticReloadCooldown,
           (didHitRateLimit || !videos.isEmpty)
        {
            return
        }

        isLoading = true
        defer {
            isLoading = false
            lastLoadAt = Date()
        }
        errorMessage = nil

        do {
            let subscriptions = try await subscriptionRepository.list()
            if subscriptions.isEmpty {
                videos = []
                didHitRateLimit = false
                return
            }

            var lists: [[VideoCard]] = []
            var failureMessages: [String] = []
            var rateLimitedFailures = 0
            var startIndex = 0

            while startIndex < subscriptions.count {
                let endIndex = min(startIndex + maxConcurrentSubscriptionFetches, subscriptions.count)
                let batch = subscriptions[startIndex..<endIndex]

                await withTaskGroup(of: Result<[VideoCard], Error>.self) { group in
                    for subscription in batch {
                        group.addTask {
                            do {
                                let cards = try await self.biliClient.fetchSubscriptionVideos(uid: subscription.uid)
                                return .success(cards)
                            } catch {
                                return .failure(error)
                            }
                        }
                    }

                    for await result in group {
                        switch result {
                        case .success(let cards):
                            lists.append(cards)
                        case .failure(let error):
                            if let known = error as? BiliClientError, known == .rateLimited {
                                rateLimitedFailures += 1
                            }
                            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            failureMessages.append(message)
                        }
                    }
                }

                startIndex = endIndex
            }

            if lists.isEmpty, !failureMessages.isEmpty {
                if rateLimitedFailures == failureMessages.count {
                    throw BiliClientError.rateLimited
                }
                let sample = failureMessages.prefix(2).joined(separator: "；")
                throw BiliClientError.networkFailed("全部订阅拉取失败。\(sample)")
            }

            if !failureMessages.isEmpty {
                if rateLimitedFailures == failureMessages.count {
                    errorMessage = "部分订阅触发风控（如 -352），建议在“订阅”页导入 SESSDATA 后重试。"
                } else {
                    let sample = failureMessages.prefix(1).joined(separator: "；")
                    errorMessage = "部分订阅加载失败：\(sample)"
                }
            }

            videos = HomeFeedAssembler.merge(lists, limit: 100)
            didHitRateLimit = false
        } catch {
            if let known = error as? BiliClientError, known == .rateLimited {
                didHitRateLimit = true
            } else {
                didHitRateLimit = false
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            videos = []
        }
    }
}
