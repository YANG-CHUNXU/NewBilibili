import Foundation
import Combine

@MainActor
public final class SearchViewModel: ObservableObject {
    private static let durationUnknownText = "未知时长"

    @Published public var keyword: String = ""
    @Published public var page: Int = 1
    @Published public private(set) var results: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let biliClient: any BiliPublicClient
    private let durationHydrator: VideoDurationHydrator
    private let maxConcurrentDurationHydration: Int
    private var durationHydrationTask: Task<Void, Never>?
    private var durationHydrationToken = UUID()

    public convenience init(
        biliClient: any BiliPublicClient,
        maxConcurrentDurationHydration: Int = 4
    ) {
        self.init(
            biliClient: biliClient,
            durationHydrator: .shared,
            maxConcurrentDurationHydration: maxConcurrentDurationHydration
        )
    }

    init(
        biliClient: any BiliPublicClient,
        durationHydrator: VideoDurationHydrator,
        maxConcurrentDurationHydration: Int = 4
    ) {
        self.biliClient = biliClient
        self.durationHydrator = durationHydrator
        self.maxConcurrentDurationHydration = max(1, maxConcurrentDurationHydration)
    }

    public func search() async {
        resetDurationHydrationState()
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let fetched = try await biliClient.searchVideos(keyword: keyword, page: page)
            let pendingBVIDs = Set(fetched.compactMap { video in
                video.durationText == nil ? video.bvid : nil
            })
            results = fetched.map { video in
                guard video.durationText == nil else {
                    return video
                }
                return VideoCard(
                    id: video.id,
                    bvid: video.bvid,
                    title: video.title,
                    coverURL: video.coverURL,
                    authorName: video.authorName,
                    authorUID: video.authorUID,
                    durationText: Self.durationUnknownText,
                    publishTime: video.publishTime
                )
            }
            scheduleDurationHydration(for: Array(pendingBVIDs))
        } catch {
            resetDurationHydrationState()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
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

        results = results.map { video in
            guard video.durationText == Self.durationUnknownText,
                  let hydrated = resolved[video.bvid]
            else {
                return video
            }
            return VideoCard(
                id: video.id,
                bvid: video.bvid,
                title: video.title,
                coverURL: video.coverURL,
                authorName: video.authorName,
                authorUID: video.authorUID,
                durationText: hydrated,
                publishTime: video.publishTime
            )
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
