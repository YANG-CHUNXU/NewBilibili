import Foundation
import Combine

@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public private(set) var stream: PlayableStream?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let bvid: String
    private let cid: Int?
    private let title: String
    private let biliClient: any BiliPublicClient
    private let historyRepository: any WatchHistoryRepository

    public init(
        bvid: String,
        cid: Int?,
        title: String,
        biliClient: any BiliPublicClient,
        historyRepository: any WatchHistoryRepository
    ) {
        self.bvid = bvid
        self.cid = cid
        self.title = title
        self.biliClient = biliClient
        self.historyRepository = historyRepository
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            stream = try await biliClient.resolvePlayableStream(bvid: bvid, cid: cid)
        } catch {
            stream = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func recordPlayback(progressSeconds: Double) async {
        guard progressSeconds.isFinite, progressSeconds >= 0 else {
            return
        }

        do {
            try await historyRepository.record(bvid: bvid, title: title, progressSeconds: progressSeconds)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
