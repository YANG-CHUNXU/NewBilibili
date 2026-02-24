import Foundation
import Combine

@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public private(set) var stream: PlayableStream?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var errorCode: String?
    @Published public private(set) var technicalDetail: String?

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
        clearError()

        do {
            stream = try await biliClient.resolvePlayableStream(bvid: bvid, cid: cid)
        } catch {
            stream = nil
            reportPlaybackError(error, fallbackCode: "NB-PL-RESOLVE")
        }
    }

    public func recordPlayback(progressSeconds: Double) async {
        guard progressSeconds.isFinite, progressSeconds >= 0 else {
            return
        }

        do {
            try await historyRepository.record(bvid: bvid, title: title, progressSeconds: progressSeconds)
        } catch {
            reportPlaybackError(error, fallbackCode: "NB-PL-HISTORY")
        }
    }

    public func reportPlaybackError(_ error: Error, fallbackCode: String = "NB-PL-UNKNOWN") {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorCode = Self.resolveErrorCode(from: error, fallback: fallbackCode)
        let nsError = error as NSError
        technicalDetail = "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
    }

    public func reportPlaybackError(message: String, code: String, technicalDetail: String? = nil) {
        errorMessage = message
        errorCode = code
        self.technicalDetail = technicalDetail
    }

    private func clearError() {
        errorMessage = nil
        errorCode = nil
        technicalDetail = nil
    }

    private static func resolveErrorCode(from error: Error, fallback: String) -> String {
        if let known = error as? BiliClientError {
            switch known {
            case .invalidInput:
                return "NB-PL-INPUT"
            case .networkFailed:
                return "NB-PL-NET"
            case .parseFailed:
                return "NB-PL-PARSE"
            case .noPlayableStream:
                return "NB-PL-NO_STREAM"
            case .rateLimited:
                return "NB-PL-RATE_LIMIT"
            case .playbackProxyFailed:
                return "NB-PL-PROXY"
            case .unsupportedDashStream:
                return "NB-PL-DASH"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "NB-PL-NET-\(abs(nsError.code))"
        }
        return fallback
    }
}
