import SwiftUI
import AVKit
import AVFoundation
import NewBiCore

struct PlayerView: View {
    @StateObject private var viewModel: PlayerViewModel
    @State private var player = AVPlayer()
    @State private var isPresentingFullScreenPlayer = false
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failedToEndObserver: NSObjectProtocol?
    @State private var isViewVisible = false
    @State private var activePlaybackSessionID = UUID()
    @State private var didRetryPlayback = false
    @State private var isRetryingPlayback = false
    @State private var lastAttemptedStream: PlayableStream?
    private let bvidForDebug: String
    private let cidForDebug: Int?
    private let playbackItemFactory: any PlaybackItemFactoryProtocol

    init(
        bvid: String,
        cid: Int?,
        title: String,
        biliClient: any BiliPublicClient,
        historyRepository: any WatchHistoryRepository,
        playbackItemFactory: any PlaybackItemFactoryProtocol
    ) {
        _viewModel = StateObject(
            wrappedValue: PlayerViewModel(
                bvid: bvid,
                cid: cid,
                title: title,
                biliClient: biliClient,
                historyRepository: historyRepository
            )
        )
        self.bvidForDebug = bvid
        self.cidForDebug = cid
        self.playbackItemFactory = playbackItemFactory
    }

    var body: some View {
        VStack(spacing: 16) {
            if let error = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .foregroundStyle(.red)
                    if let code = viewModel.errorCode {
                        Text("错误码: \(code)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let technical = viewModel.technicalDetail, !technical.isEmpty {
                        Text("技术详情: \(technical)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if let stream = viewModel.stream {
                ZStack(alignment: .topTrailing) {
                    VideoPlayer(player: player)
                        .frame(minHeight: 220)

                    Button {
                        isPresentingFullScreenPlayer = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.headline)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(10)
                    .accessibilityLabel("全屏播放")
                }
                .task(id: stream) {
                    let sessionID = beginPlaybackSession()
                    await preparePlayback(for: stream, sessionID: sessionID)
                }
                Text("清晰度: \(stream.qualityLabel) | 格式: \(stream.format)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.isLoading {
                ProgressView("解析播放地址...")
            } else {
                Text("暂无可播放流")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical)
        .navigationTitle("播放器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .onAppear {
            isViewVisible = true
        }
        .onDisappear {
            guard !isPresentingFullScreenPlayer else {
                return
            }
            isViewVisible = false
            invalidatePlaybackSession()
            let seconds = player.currentTime().seconds
            Task {
                await viewModel.recordPlayback(progressSeconds: seconds.isFinite ? seconds : 0)
            }
            teardownPlayer()
        }
        .fullScreenCover(isPresented: $isPresentingFullScreenPlayer) {
            FullScreenPlayerView(player: player)
        }
    }

    private func beginPlaybackSession() -> UUID {
        let sessionID = UUID()
        activePlaybackSessionID = sessionID
        return sessionID
    }

    private func invalidatePlaybackSession() {
        activePlaybackSessionID = UUID()
    }

    private func shouldHandlePlaybackResult(for sessionID: UUID) -> Bool {
        !Task.isCancelled && isViewVisible && activePlaybackSessionID == sessionID
    }

    @MainActor
    private func preparePlayback(for stream: PlayableStream, sessionID: UUID) async {
        do {
            configureAudioSessionForPlayback()
            lastAttemptedStream = stream
            let item = try await playbackItemFactory.makePlayerItem(from: stream)
            guard shouldHandlePlaybackResult(for: sessionID) else {
                playbackItemFactory.releaseResources(for: item)
                return
            }
            bindFailureObservers(to: item, sessionID: sessionID)
            player.pause()
            playbackItemFactory.releaseResources(for: player.currentItem)
            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            guard shouldHandlePlaybackResult(for: sessionID) else {
                return
            }
            await handlePlaybackFailure(error, sessionID: sessionID)
        }
    }

    @MainActor
    private func bindFailureObservers(to item: AVPlayerItem, sessionID: UUID) {
        clearObservers()
        statusObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
            guard observedItem.status == .failed else {
                return
            }
            let err = observedItem.error ?? BiliClientError.playbackProxyFailed("播放器加载失败")
            Task { @MainActor in
                await self.handlePlaybackFailure(err, sessionID: sessionID)
            }
        }

        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let err = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ??
                BiliClientError.playbackProxyFailed("播放中断")
            Task { @MainActor in
                await self.handlePlaybackFailure(err, sessionID: sessionID)
            }
        }
    }

    @MainActor
    private func handlePlaybackFailure(_ error: Error, sessionID: UUID) async {
        guard shouldHandlePlaybackResult(for: sessionID) else {
            return
        }

        if !didRetryPlayback, !isRetryingPlayback {
            didRetryPlayback = true
            isRetryingPlayback = true
            await viewModel.load()
            guard shouldHandlePlaybackResult(for: sessionID) else {
                isRetryingPlayback = false
                return
            }
            if let stream = viewModel.stream {
                let retrySessionID = beginPlaybackSession()
                await preparePlayback(for: makeRetryStream(from: stream), sessionID: retrySessionID)
            } else {
                let diagnostic = makePlaybackDiagnostic(from: error)
                logPlaybackDiagnostic(diagnostic)
                viewModel.reportPlaybackError(
                    message: diagnostic.userMessage,
                    code: diagnostic.code,
                    technicalDetail: diagnostic.technicalDetail
                )
            }
            isRetryingPlayback = false
            return
        }

        let diagnostic = makePlaybackDiagnostic(from: error)
        logPlaybackDiagnostic(diagnostic)
        viewModel.reportPlaybackError(
            message: diagnostic.userMessage,
            code: diagnostic.code,
            technicalDetail: diagnostic.technicalDetail
        )
    }

    private func makeRetryStream(from stream: PlayableStream) -> PlayableStream {
        guard let lastAttemptedStream, stream == lastAttemptedStream else {
            return stream
        }

        switch stream.transport {
        case .progressive(let url, let fallbackURLs):
            guard let next = fallbackURLs.first else {
                return stream
            }
            let rotatedFallbacks = Array(fallbackURLs.dropFirst()) + [url]
            return PlayableStream(
                transport: .progressive(url: next, fallbackURLs: rotatedFallbacks),
                headers: stream.headers,
                qualityLabel: stream.qualityLabel,
                format: stream.format
            )
        case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs):
            let rotatedVideo = rotate(primary: videoURL, fallbacks: videoFallbackURLs)
            let rotatedAudio: (URL?, [URL])
            if let audioURL {
                let next = rotate(primary: audioURL, fallbacks: audioFallbackURLs)
                rotatedAudio = (next.primary, next.fallbacks)
            } else {
                rotatedAudio = (nil, [])
            }

            return PlayableStream(
                transport: .dash(
                    videoURL: rotatedVideo.primary,
                    audioURL: rotatedAudio.0,
                    videoFallbackURLs: rotatedVideo.fallbacks,
                    audioFallbackURLs: rotatedAudio.1
                ),
                headers: stream.headers,
                qualityLabel: stream.qualityLabel,
                format: stream.format
            )
        }
    }

    private func rotate(primary: URL, fallbacks: [URL]) -> (primary: URL, fallbacks: [URL]) {
        guard let next = fallbacks.first else {
            return (primary, fallbacks)
        }
        let rotatedFallbacks = Array(fallbacks.dropFirst()) + [primary]
        return (next, rotatedFallbacks)
    }

    private func configureAudioSessionForPlayback() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // Do not block playback when audio session setup fails.
        }
        #endif
    }

    private func makePlaybackDiagnostic(from error: Error) -> PlaybackDiagnostic {
        let nsError = error as NSError
        let technical = buildTechnicalDetail(from: nsError, stream: lastAttemptedStream)
        if nsError.domain == "CoreMediaErrorDomain", nsError.code == -12881 {
            return PlaybackDiagnostic(
                code: "NB-PL-CM-12881",
                userMessage: "视频资源加载失败（CoreMedia -12881）。请返回后重试，若仍失败请更换视频测试。",
                technicalDetail: technical
            )
        }
        if nsError.code == -50 {
            return PlaybackDiagnostic(
                code: "NB-PL-CM-50",
                userMessage: "播放器参数异常（-50），已应用兼容修复。请重试播放。",
                technicalDetail: technical
            )
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == -1022 {
            return PlaybackDiagnostic(
                code: "NB-PL-ATS-1022",
                userMessage: "网络策略拦截了非 HTTPS 资源（ATS -1022）。已启用 HTTPS 升级，请重试。",
                technicalDetail: technical
            )
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == -1004 {
            return PlaybackDiagnostic(
                code: "NB-PL-NET-1004",
                userMessage: "无法连接到视频服务器（-1004）。请稍后重试或切换网络。",
                technicalDetail: technical
            )
        }
        if nsError.domain == AVFoundationErrorDomain || nsError.domain == NSOSStatusErrorDomain {
            let text = (nsError.localizedDescription as NSString).lowercased
            if isLikelyUnsupportedFLV(stream: lastAttemptedStream) {
                return PlaybackDiagnostic(
                    code: "NB-PL-AV-FLV_UNSUPPORTED",
                    userMessage: "当前视频仅返回 FLV/非原生可播流，已回退仍失败。请切换视频或稍后再试。",
                    technicalDetail: technical
                )
            }
            if text.contains("cannot open") || text.contains("无法打开") {
                return PlaybackDiagnostic(
                    code: "NB-PL-AV-CANNOT_OPEN",
                    userMessage: "视频源不可打开，已尝试备用地址仍失败。请切换网络或稍后再试。",
                    technicalDetail: technical
                )
            }
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let known = error as? BiliClientError {
            let code: String
            switch known {
            case .invalidInput:
                code = "NB-PL-INPUT"
            case .networkFailed:
                code = "NB-PL-NET"
            case .parseFailed:
                code = "NB-PL-PARSE"
            case .noPlayableStream:
                code = "NB-PL-NO_STREAM"
            case .rateLimited:
                code = "NB-PL-RATE_LIMIT"
            case .playbackProxyFailed:
                code = "NB-PL-PROXY"
            case .unsupportedDashStream:
                code = "NB-PL-DASH"
            }
            return PlaybackDiagnostic(code: code, userMessage: message, technicalDetail: technical)
        }

        return PlaybackDiagnostic(code: "NB-PL-UNKNOWN", userMessage: message, technicalDetail: technical)
    }

    private func isLikelyUnsupportedFLV(stream: PlayableStream?) -> Bool {
        guard let stream,
              case .progressive(let url, _) = stream.transport
        else {
            return false
        }

        let format = stream.format.lowercased()
        let ext = url.pathExtension.lowercased()
        return format.contains("flv") || ext == "flv" || ext == "f4v"
    }

    private func buildTechnicalDetail(from nsError: NSError, stream: PlayableStream?) -> String {
        var details: [String] = [
            "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
        ]

        if let stream {
            switch stream.transport {
            case .progressive(let url, let fallbackURLs):
                details.append("stream=progressive format=\(stream.format)")
                details.append("url=\(url.absoluteString)")
                details.append("fallback_count=\(fallbackURLs.count)")
            case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs):
                details.append("stream=dash format=\(stream.format)")
                details.append("video=\(videoURL.absoluteString)")
                if let audioURL {
                    details.append("audio=\(audioURL.absoluteString)")
                } else {
                    details.append("audio=nil")
                }
                details.append("video_fallback_count=\(videoFallbackURLs.count)")
                details.append("audio_fallback_count=\(audioFallbackURLs.count)")
            }
        }

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            details.append("failing_url=\(failingURL.absoluteString)")
        } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            details.append("failing_url=\(failingURLString)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying=\(underlying.domain)#\(underlying.code): \(underlying.localizedDescription)")
        }

        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            details.append("reason=\(failureReason)")
        }

        return details.joined(separator: " | ")
    }

    private func logPlaybackDiagnostic(_ diagnostic: PlaybackDiagnostic) {
        let cidText = cidForDebug.map(String.init) ?? "nil"
        print(
            "[NEWBI_PLAYBACK_ERROR] code=\(diagnostic.code) bvid=\(bvidForDebug) cid=\(cidText) detail=\(diagnostic.technicalDetail ?? "none")"
        )
    }

    @MainActor
    private func clearObservers() {
        statusObserver?.invalidate()
        statusObserver = nil

        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }

    @MainActor
    private func teardownPlayer() {
        player.pause()
        clearObservers()
        playbackItemFactory.releaseResources(for: player.currentItem)
        player.replaceCurrentItem(with: nil)
        lastAttemptedStream = nil
    }
}

private struct PlaybackDiagnostic {
    let code: String
    let userMessage: String
    let technicalDetail: String?
}

private struct FullScreenPlayerView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            FullScreenPlayerController(player: player)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("退出全屏")
        }
    }
}

private struct FullScreenPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
