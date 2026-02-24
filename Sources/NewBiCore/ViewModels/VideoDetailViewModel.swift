import Foundation
import Combine

@MainActor
public final class VideoDetailViewModel: ObservableObject {
    @Published public private(set) var detail: VideoDetail?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let bvid: String
    private let biliClient: any BiliPublicClient

    public init(bvid: String, biliClient: any BiliPublicClient) {
        self.bvid = bvid
        self.biliClient = biliClient
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            detail = try await biliClient.fetchVideoDetail(bvid: bvid)
        } catch {
            detail = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
