import Foundation
import Combine

@MainActor
public final class HomeFeedViewModel: ObservableObject {
    private static let durationUnknownText = "未知时长"

    @Published public private(set) var videos: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let automaticReloadCooldown: TimeInterval
    private let maxConcurrentSubscriptionFetches: Int
    private let maxConcurrentDurationHydration: Int
    private let subscriptionRepository: any SubscriptionRepository
    private let biliClient: any BiliPublicClient
    private let durationHydrator: VideoDurationHydrator
    private var lastLoadAt: Date?
    private var didHitRateLimit = false
    private var durationHydrationTask: Task<Void, Never>?
    private var durationHydrationToken = UUID()

    public convenience init(
        subscriptionRepository: any SubscriptionRepository,
        biliClient: any BiliPublicClient,
        automaticReloadCooldown: TimeInterval = 30,
        maxConcurrentSubscriptionFetches: Int = 2,
        maxConcurrentDurationHydration: Int = 4
    ) {
        self.init(
            subscriptionRepository: subscriptionRepository,
            biliClient: biliClient,
            automaticReloadCooldown: automaticReloadCooldown,
            maxConcurrentSubscriptionFetches: maxConcurrentSubscriptionFetches,
            durationHydrator: .shared,
            maxConcurrentDurationHydration: maxConcurrentDurationHydration
        )
    }

    init(
        subscriptionRepository: any SubscriptionRepository,
        biliClient: any BiliPublicClient,
        automaticReloadCooldown: TimeInterval = 30,
        maxConcurrentSubscriptionFetches: Int = 2,
        durationHydrator: VideoDurationHydrator,
        maxConcurrentDurationHydration: Int = 4
    ) {
        self.subscriptionRepository = subscriptionRepository
        self.biliClient = biliClient
        self.automaticReloadCooldown = max(0, automaticReloadCooldown)
        self.maxConcurrentSubscriptionFetches = max(1, maxConcurrentSubscriptionFetches)
        self.durationHydrator = durationHydrator
        self.maxConcurrentDurationHydration = max(1, maxConcurrentDurationHydration)
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

        resetDurationHydrationState()
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

            let merged = HomeFeedAssembler.merge(lists, limit: 100)
            let pendingBVIDs = Set(merged.compactMap { video in
                video.durationText == nil ? video.bvid : nil
            })
            videos = merged.map { video in
                guard video.durationText == nil else {
                    return video
                }
                return video.replacingDurationText(Self.durationUnknownText)
            }
            scheduleDurationHydration(for: Array(pendingBVIDs))
            didHitRateLimit = false
        } catch {
            resetDurationHydrationState()
            if let known = error as? BiliClientError, known == .rateLimited {
                didHitRateLimit = true
            } else {
                didHitRateLimit = false
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            videos = []
        }
    }

    private func resetDurationHydrationState() {
        durationHydrationTask?.cancel()
        durationHydrationTask = nil
        durationHydrationToken = UUID()
    }

    private func scheduleDurationHydration(for bvids: [String]) {
        guard !bvids.isEmpty else {
            return
        }

        let token = durationHydrationToken
        let client = biliClient
        let hydrator = durationHydrator
        let maxConcurrent = maxConcurrentDurationHydration

        durationHydrationTask = Task { [weak self] in
            let resolved = await Self.resolveDurations(
                for: bvids,
                client: client,
                hydrator: hydrator,
                maxConcurrent: maxConcurrent
            )
            guard !Task.isCancelled else {
                return
            }
            self?.applyResolvedDurations(resolved, token: token)
        }
    }

    private func applyResolvedDurations(_ resolved: [String: String], token: UUID) {
        guard token == durationHydrationToken else {
            return
        }
        guard !resolved.isEmpty else {
            return
        }

        videos = videos.map { video in
            guard video.durationText == Self.durationUnknownText,
                  let hydrated = resolved[video.bvid]
            else {
                return video
            }
            return video.replacingDurationText(hydrated)
        }
    }

    nonisolated private static func resolveDurations(
        for bvids: [String],
        client: any BiliPublicClient,
        hydrator: VideoDurationHydrator,
        maxConcurrent: Int
    ) async -> [String: String] {
        var resolved: [String: String] = [:]
        let cappedConcurrency = max(1, maxConcurrent)
        var start = 0

        while start < bvids.count {
            let end = min(start + cappedConcurrency, bvids.count)
            let batch = Array(bvids[start..<end])

            await withTaskGroup(of: (String, String?).self) { group in
                for bvid in batch {
                    group.addTask {
                        let duration = await hydrator.resolveDurationText(bvid: bvid, using: client)
                        return (bvid, duration)
                    }
                }

                for await (bvid, duration) in group {
                    if let duration {
                        resolved[bvid] = duration
                    }
                }
            }

            start = end
        }

        return resolved
    }
}

private extension VideoCard {
    func replacingDurationText(_ durationText: String?) -> VideoCard {
        VideoCard(
            id: id,
            bvid: bvid,
            title: title,
            coverURL: coverURL,
            authorName: authorName,
            authorUID: authorUID,
            durationText: durationText,
            publishTime: publishTime
        )
    }
}
