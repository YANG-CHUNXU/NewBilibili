import Foundation
import Combine

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var keyword: String = ""
    @Published public var page: Int = 1
    @Published public private(set) var results: [VideoCard] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let biliClient: any BiliPublicClient

    public init(biliClient: any BiliPublicClient) {
        self.biliClient = biliClient
    }

    public func search() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            results = try await biliClient.searchVideos(keyword: keyword, page: page)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
    }
}
