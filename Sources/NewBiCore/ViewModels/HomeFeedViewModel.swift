import Foundation
import Combine

@MainActor
public final class HomeFeedViewModel: ObservableObject {
    @Published public private(set) var videos: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let subscriptionRepository: any SubscriptionRepository
    private let biliClient: any BiliPublicClient

    public init(subscriptionRepository: any SubscriptionRepository, biliClient: any BiliPublicClient) {
        self.subscriptionRepository = subscriptionRepository
        self.biliClient = biliClient
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let subscriptions = try await subscriptionRepository.list()
            if subscriptions.isEmpty {
                videos = []
                return
            }

            var lists: [[VideoCard]] = []
            var failureMessages: [String] = []

            await withTaskGroup(of: Result<[VideoCard], Error>.self) { group in
                for subscription in subscriptions {
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
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        failureMessages.append(message)
                    }
                }
            }

            if lists.isEmpty, !failureMessages.isEmpty {
                let sample = failureMessages.prefix(2).joined(separator: "；")
                throw BiliClientError.networkFailed("全部订阅拉取失败。\(sample)")
            }

            if !failureMessages.isEmpty {
                let sample = failureMessages.prefix(1).joined(separator: "；")
                errorMessage = "部分订阅加载失败：\(sample)"
            }

            videos = HomeFeedAssembler.merge(lists, limit: 100)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            videos = []
        }
    }
}
