import Foundation
import Combine

@MainActor
public final class HomeFeedViewModel: ObservableObject {
    private static let durationUnknownText = "未知时长"
    private static let followingWindowSeconds: TimeInterval = 24 * 60 * 60
    private static let maxFollowingPages = 3
    private static let mergedLimit = 100

    @Published public private(set) var videos: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let automaticReloadCooldown: TimeInterval
    private let maxConcurrentDurationHydration: Int
    private let isAuthenticatedProvider: () -> Bool
    private let biliClient: any BiliPublicClient
    private let durationHydrator: VideoDurationHydrator
    private var lastLoadAt: Date?
    private var didHitRateLimit = false
    private var durationHydrationTask: Task<Void, Never>?
    private var durationHydrationToken = UUID()

    public convenience init(
        biliClient: any BiliPublicClient,
        automaticReloadCooldown: TimeInterval = 30,
        maxConcurrentDurationHydration: Int = 4,
        isAuthenticatedProvider: @escaping () -> Bool = { true }
    ) {
        self.init(
            biliClient: biliClient,
            automaticReloadCooldown: automaticReloadCooldown,
            durationHydrator: .shared,
            maxConcurrentDurationHydration: maxConcurrentDurationHydration,
            isAuthenticatedProvider: isAuthenticatedProvider
        )
    }

    init(
        biliClient: any BiliPublicClient,
        automaticReloadCooldown: TimeInterval = 30,
        durationHydrator: VideoDurationHydrator,
        maxConcurrentDurationHydration: Int = 4,
        isAuthenticatedProvider: @escaping () -> Bool = { true }
    ) {
        self.biliClient = biliClient
        self.automaticReloadCooldown = max(0, automaticReloadCooldown)
        self.durationHydrator = durationHydrator
        self.maxConcurrentDurationHydration = max(1, maxConcurrentDurationHydration)
        self.isAuthenticatedProvider = isAuthenticatedProvider
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

        guard isAuthenticatedProvider() else {
            videos = []
            didHitRateLimit = false
            errorMessage = BiliClientError.authRequired("请先在“我的”页登录 B 站账号").errorDescription
            return
        }

        do {
            let cards = try await biliClient.fetchFollowingVideos(maxPages: Self.maxFollowingPages)
            let cutoff = Date().addingTimeInterval(-Self.followingWindowSeconds)
            let oneDayCards = cards.filter { card in
                guard let publishTime = card.publishTime else {
                    return false
                }
                return publishTime >= cutoff
            }
            let merged = HomeFeedAssembler.merge([oneDayCards], limit: Self.mergedLimit)
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
