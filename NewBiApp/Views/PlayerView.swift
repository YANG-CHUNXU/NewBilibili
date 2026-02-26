import SwiftUI
import AVKit
import AVFoundation
import NewBiCore

struct PlayerView: View {
    private static let compatibilityRetryBudget: TimeInterval = 6
    private static let maxCompatibilityDirectAttempts = 5

    @StateObject private var viewModel: PlayerViewModel
    @State private var player = AVPlayer()
    @State private var isPresentingFullScreenPlayer = false
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failedToEndObserver: NSObjectProtocol?
    @State private var didPlayToEndObserver: NSObjectProtocol?
    @State private var periodicTimeObserverToken: Any?
    @State private var lastSyncedProgressSeconds: Double = 0
    @State private var lastSyncAt: Date = .distantPast
    @State private var isViewVisible = false
    @State private var activePlaybackSessionID = UUID()
    @State private var isRetryingPlayback = false
    @State private var pendingRetryAttempts: [PlaybackAttempt] = []
    @State private var triedAttemptKeys = Set<String>()
    @State private var retryDeadline: Date?
    @State private var retryAttemptIndex = 1
    @State private var retryAttemptTotal = 1
    @State private var retryPlanInitialized = false
    @State private var retryReason: PlaybackRetryReason = .nonCompatibility
    @State private var lastAttemptedStream: PlayableStream?
    @State private var lastAttemptedMode: PlaybackBuildMode = .directPreferred
    @State private var lastAttemptReasonTag = "initial"
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
                    resetRetryStateForFreshPlayback()
                    await preparePlayback(
                        for: stream,
                        mode: .directPreferred,
                        reasonTag: "initial",
                        sessionID: sessionID
                    )
                }
                qualitySelector(for: stream)
                Text("格式: \(stream.format)")
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
            resetRetryStateForFreshPlayback()
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
    private func preparePlayback(
        for stream: PlayableStream,
        mode: PlaybackBuildMode,
        reasonTag: String,
        sessionID: UUID
    ) async {
        do {
            configureAudioSessionForPlayback()
            lastAttemptedStream = stream
            lastAttemptedMode = mode
            lastAttemptReasonTag = reasonTag
            triedAttemptKeys.insert(attemptKey(for: stream, mode: mode))
            let item = try await playbackItemFactory.makePlayerItem(from: stream, mode: mode)
            guard shouldHandlePlaybackResult(for: sessionID) else {
                playbackItemFactory.releaseResources(for: item)
                return
            }
            bindFailureObservers(to: item, sessionID: sessionID)
            lastSyncedProgressSeconds = 0
            lastSyncAt = .distantPast
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

        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            let duration = item.duration.seconds
            let finalSeconds = duration.isFinite && duration > 0 ? duration : self.player.currentTime().seconds
            Task {
                await self.viewModel.recordPlayback(progressSeconds: finalSeconds.isFinite ? finalSeconds : 0)
            }
        }

        periodicTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0 else {
                return
            }
            let now = Date()
            guard now.timeIntervalSince(self.lastSyncAt) >= 5 else {
                return
            }
            guard abs(seconds - self.lastSyncedProgressSeconds) >= 1 || self.lastSyncAt == .distantPast else {
                return
            }
            self.lastSyncAt = now
            self.lastSyncedProgressSeconds = seconds
            Task {
                await self.viewModel.recordPlayback(progressSeconds: seconds)
            }
        }
    }

    @MainActor
    private func handlePlaybackFailure(_ error: Error, sessionID: UUID) async {
        guard shouldHandlePlaybackResult(for: sessionID) else {
            return
        }

        guard !isRetryingPlayback else {
            return
        }

        isRetryingPlayback = true
        let nextAttempt = nextRetryAttempt(after: error)
        isRetryingPlayback = false

        if let nextAttempt {
            guard shouldHandlePlaybackResult(for: sessionID) else {
                return
            }
            retryAttemptIndex += 1
            let retrySessionID = beginPlaybackSession()
            await preparePlayback(
                for: nextAttempt.stream,
                mode: nextAttempt.mode,
                reasonTag: nextAttempt.reasonTag,
                sessionID: retrySessionID
            )
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

    @MainActor
    private func nextRetryAttempt(after error: Error) -> PlaybackAttempt? {
        if !retryPlanInitialized {
            retryPlanInitialized = true
            let compatibility = isCompatibilityFailure(error)
            retryReason = compatibility ? .compatibility : .nonCompatibility
            retryDeadline = compatibility ? Date().addingTimeInterval(Self.compatibilityRetryBudget) : nil

            guard let baseStream = lastAttemptedStream ?? viewModel.stream else {
                retryAttemptTotal = max(retryAttemptIndex, 1)
                return nil
            }

            if compatibility {
                pendingRetryAttempts = buildCompatibilityRetryAttempts(
                    from: baseStream,
                    qualityOptions: viewModel.qualityOptions
                )
            } else {
                pendingRetryAttempts = buildNonCompatibilityRetryAttempts(
                    from: baseStream,
                    qualityOptions: viewModel.qualityOptions
                )
            }
            retryAttemptTotal = max(retryAttemptIndex + pendingRetryAttempts.count, retryAttemptIndex)
        }

        if retryReason == .compatibility,
           let retryDeadline,
           Date() >= retryDeadline
        {
            pendingRetryAttempts.removeAll()
            return nil
        }

        while let next = pendingRetryAttempts.first {
            pendingRetryAttempts.removeFirst()
            let key = attemptKey(for: next.stream, mode: next.mode)
            guard triedAttemptKeys.insert(key).inserted else {
                continue
            }
            return next
        }

        return nil
    }

    private func buildNonCompatibilityRetryAttempts(
        from stream: PlayableStream,
        qualityOptions: [PlayableStream]
    ) -> [PlaybackAttempt] {
        let retry = makeRetryStream(
            from: stream,
            qualityOptions: qualityOptions,
            prioritizeCompatibility: false
        )
        guard retry != stream else {
            return []
        }
        return [
            PlaybackAttempt(
                stream: retry,
                mode: .directPreferred,
                reasonTag: "non-compat-direct"
            )
        ]
    }

    private func buildCompatibilityRetryAttempts(
        from stream: PlayableStream,
        qualityOptions: [PlayableStream]
    ) -> [PlaybackAttempt] {
        switch stream.transport {
        case .progressive, .progressivePlaylist:
            let retry = makeRetryStream(
                from: stream,
                qualityOptions: qualityOptions,
                prioritizeCompatibility: true
            )
            guard retry != stream else {
                return []
            }
            return [
                PlaybackAttempt(
                    stream: retry,
                    mode: .directPreferred,
                    reasonTag: "compat-progressive"
                )
            ]
        case .dash:
            break
        }

        var rawDirectAttempts: [PlaybackAttempt] = []
        let currentNoAudio = streamWithoutExternalAudioIfPossible(stream)
        if currentNoAudio != stream {
            rawDirectAttempts.append(
                PlaybackAttempt(
                    stream: currentNoAudio,
                    mode: .directPreferred,
                    reasonTag: "compat-current-audio-off"
                )
            )
        }

        for rotated in dashVideoFallbackVariants(from: currentNoAudio) {
            rawDirectAttempts.append(
                PlaybackAttempt(
                    stream: rotated,
                    mode: .directPreferred,
                    reasonTag: "compat-current-rotate"
                )
            )
        }

        let lowerQualities = strictlyLowerQualityStreams(from: stream, options: qualityOptions)
        for lower in lowerQualities {
            let lowerNoAudio = streamWithoutExternalAudioIfPossible(lower)
            rawDirectAttempts.append(
                PlaybackAttempt(
                    stream: lowerNoAudio,
                    mode: .directPreferred,
                    reasonTag: "compat-lower-audio-off"
                )
            )

            for rotated in dashVideoFallbackVariants(from: lowerNoAudio) {
                rawDirectAttempts.append(
                    PlaybackAttempt(
                        stream: rotated,
                        mode: .directPreferred,
                        reasonTag: "compat-lower-rotate"
                    )
                )
            }
        }

        var attempts: [PlaybackAttempt] = []
        var seenKeys = triedAttemptKeys
        for attempt in rawDirectAttempts {
            let key = attemptKey(for: attempt.stream, mode: attempt.mode)
            guard seenKeys.insert(key).inserted else {
                continue
            }
            attempts.append(attempt)
            if attempts.count >= Self.maxCompatibilityDirectAttempts {
                break
            }
        }

        let proxyBaseStream = attempts.first?.stream ?? currentNoAudio
        let proxyAttempt = PlaybackAttempt(
            stream: proxyBaseStream,
            mode: .proxyOnly,
            reasonTag: "compat-proxy-last"
        )
        let proxyKey = attemptKey(for: proxyAttempt.stream, mode: proxyAttempt.mode)
        if seenKeys.insert(proxyKey).inserted {
            attempts.append(proxyAttempt)
        }

        return attempts
    }

    private func makeRetryStream(
        from stream: PlayableStream,
        qualityOptions: [PlayableStream],
        prioritizeCompatibility: Bool
    ) -> PlayableStream {
        switch stream.transport {
        case .progressive(let url, let fallbackURLs):
            if prioritizeCompatibility,
               let strictLower = strictlyLowerQualityStreams(from: stream, options: qualityOptions).first
            {
                return strictLower
            }

            if let next = fallbackURLs.first {
                let rotatedFallbacks = Array(fallbackURLs.dropFirst()) + [url]
                return makeStream(
                    from: stream,
                    transport: .progressive(url: next, fallbackURLs: rotatedFallbacks)
                )
            }

            if prioritizeCompatibility {
                return stream
            }

            guard let downgraded = nextLowerQualityStream(from: stream, options: qualityOptions) else {
                return stream
            }
            return downgraded
        case .progressivePlaylist:
            if let strictLower = strictlyLowerQualityStreams(from: stream, options: qualityOptions).first {
                return strictLower
            }

            if prioritizeCompatibility {
                return stream
            }

            guard let downgraded = nextLowerQualityStream(from: stream, options: qualityOptions) else {
                return stream
            }
            return downgraded
        case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs):
            let rotatedVideo = rotate(primary: videoURL, fallbacks: videoFallbackURLs)
            let rotatedAudio: (URL?, [URL])
            if let audioURL {
                let next = rotate(primary: audioURL, fallbacks: audioFallbackURLs)
                rotatedAudio = (next.primary, next.fallbacks)
            } else {
                rotatedAudio = (nil, [])
            }

            let rotatedStream = makeStream(
                from: stream,
                transport: .dash(
                    videoURL: rotatedVideo.primary,
                    audioURL: rotatedAudio.0,
                    videoFallbackURLs: rotatedVideo.fallbacks,
                    audioFallbackURLs: rotatedAudio.1
                )
            )
            if rotatedStream != stream {
                return rotatedStream
            }

            guard let downgraded = nextLowerQualityStream(from: stream, options: qualityOptions) else {
                return stream
            }
            return downgraded
        }
    }

    private func strictlyLowerQualityStreams(from current: PlayableStream, options: [PlayableStream]) -> [PlayableStream] {
        guard let currentQualityID = current.qualityID else {
            return []
        }

        var seen = Set<String>()
        return options
            .filter { option in
                guard option.qualitySelectionKey != current.qualitySelectionKey,
                      let qualityID = option.qualityID
                else {
                    return false
                }
                return qualityID < currentQualityID
            }
            .sorted { lhs, rhs in
                let lhsID = lhs.qualityID ?? Int.min
                let rhsID = rhs.qualityID ?? Int.min
                return lhsID > rhsID
            }
            .filter { option in
                seen.insert(option.qualitySelectionKey).inserted
            }
    }

    private func dashVideoFallbackVariants(from stream: PlayableStream) -> [PlayableStream] {
        guard case .dash = stream.transport else {
            return []
        }

        let originalSignature = streamTransportSignature(stream)
        var variants: [PlayableStream] = []
        var seenSignatures = Set<String>()
        var current = stream

        guard case .dash(_, _, let videoFallbacks, _) = current.transport, !videoFallbacks.isEmpty else {
            return []
        }

        for _ in 0..<videoFallbacks.count {
            let next = rotatedDashVideoStream(from: current)
            let signature = streamTransportSignature(next)
            guard signature != originalSignature else {
                current = next
                continue
            }
            if seenSignatures.insert(signature).inserted {
                variants.append(next)
            }
            current = next
        }

        return variants
    }

    private func rotatedDashVideoStream(from stream: PlayableStream) -> PlayableStream {
        guard case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs) = stream.transport else {
            return stream
        }

        let rotatedVideo = rotate(primary: videoURL, fallbacks: videoFallbackURLs)
        return makeStream(
            from: stream,
            transport: .dash(
                videoURL: rotatedVideo.primary,
                audioURL: audioURL,
                videoFallbackURLs: rotatedVideo.fallbacks,
                audioFallbackURLs: audioFallbackURLs
            )
        )
    }

    private func nextLowerQualityStream(from current: PlayableStream, options: [PlayableStream]) -> PlayableStream? {
        let candidates = options.filter { $0.qualitySelectionKey != current.qualitySelectionKey }
        guard !candidates.isEmpty else {
            return nil
        }

        guard let currentQualityID = current.qualityID else {
            return candidates.first
        }

        if let lower = candidates
            .compactMap({ option -> (Int, PlayableStream)? in
                guard let qualityID = option.qualityID, qualityID < currentQualityID else {
                    return nil
                }
                return (qualityID, option)
            })
            .sorted(by: { $0.0 > $1.0 })
            .first?.1
        {
            return lower
        }

        return candidates
            .compactMap({ option -> (Int, PlayableStream)? in
                guard let qualityID = option.qualityID else {
                    return nil
                }
                return (qualityID, option)
            })
            .sorted(by: { $0.0 < $1.0 })
            .first?.1 ?? candidates.first
    }

    private func isCompatibilityFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if containsError(nsError, domain: AVFoundationErrorDomain, code: -11828) {
            return true
        }
        if containsError(nsError, domain: "CoreMediaErrorDomain", code: -12881) {
            return true
        }
        if containsError(nsError, domain: NSOSStatusErrorDomain, code: -12847) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        if message.contains("cannot open") || message.contains("not supported") {
            return true
        }

        if let reason = nsError.localizedFailureReason?.lowercased(),
           reason.contains("not supported")
        {
            return true
        }

        return false
    }

    private func containsError(_ root: NSError, domain: String, code: Int) -> Bool {
        var pending: [NSError] = [root]
        var visited = Set<ObjectIdentifier>()

        while let current = pending.popLast() {
            let identifier = ObjectIdentifier(current)
            guard visited.insert(identifier).inserted else {
                continue
            }

            if current.domain == domain, current.code == code {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
        }

        return false
    }

    private func streamWithoutExternalAudioIfPossible(_ stream: PlayableStream) -> PlayableStream {
        guard case .dash(let videoURL, let audioURL, let videoFallbackURLs, _) = stream.transport,
              audioURL != nil
        else {
            return stream
        }

        return makeStream(
            from: stream,
            transport: .dash(
                videoURL: videoURL,
                audioURL: nil,
                videoFallbackURLs: videoFallbackURLs,
                audioFallbackURLs: []
            )
        )
    }

    private func makeStream(from stream: PlayableStream, transport: PlayTransport) -> PlayableStream {
        PlayableStream(
            transport: transport,
            headers: stream.headers,
            qualityID: stream.qualityID,
            qualityLabel: stream.qualityLabel,
            format: stream.format,
            qualityOptions: stream.qualityOptions
        )
    }

    private func attemptKey(for stream: PlayableStream, mode: PlaybackBuildMode) -> String {
        "\(mode.rawValue)|\(streamTransportSignature(stream))"
    }

    private func streamTransportSignature(_ stream: PlayableStream) -> String {
        switch stream.transport {
        case .progressive(let url, let fallbackURLs):
            let fallbackText = fallbackURLs.map(\.absoluteString).joined(separator: ",")
            return "progressive|\(url.absoluteString)|\(fallbackText)"
        case .progressivePlaylist(let segments):
            let firstURL = segments.first?.url.absoluteString ?? "nil"
            return "progressivePlaylist|\(firstURL)|count=\(segments.count)"
        case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs):
            let audioText = audioURL?.absoluteString ?? "nil"
            let videoFallbackText = videoFallbackURLs.map(\.absoluteString).joined(separator: ",")
            let audioFallbackText = audioFallbackURLs.map(\.absoluteString).joined(separator: ",")
            return "dash|\(videoURL.absoluteString)|\(audioText)|\(videoFallbackText)|\(audioFallbackText)"
        }
    }

    private func resetRetryStateForFreshPlayback() {
        pendingRetryAttempts = []
        triedAttemptKeys = []
        retryDeadline = nil
        retryAttemptIndex = 1
        retryAttemptTotal = 1
        retryPlanInitialized = false
        retryReason = .nonCompatibility
        lastAttemptedMode = .directPreferred
        lastAttemptReasonTag = "initial"
    }

    @ViewBuilder
    private func qualitySelector(for stream: PlayableStream) -> some View {
        if viewModel.qualityOptions.count > 1 {
            let selectedKey = viewModel.selectedQualityKey ?? stream.qualitySelectionKey
            HStack(spacing: 8) {
                Text("清晰度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(viewModel.qualityOptions, id: \.qualitySelectionKey) { option in
                        Button {
                            resetRetryStateForFreshPlayback()
                            viewModel.selectQuality(with: option.qualitySelectionKey)
                        } label: {
                            if selectedKey == option.qualitySelectionKey {
                                Label(option.qualityLabel, systemImage: "checkmark")
                            } else {
                                Text(option.qualityLabel)
                            }
                        }
                    }
                } label: {
                    Label(stream.qualityLabel, systemImage: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            .padding(.horizontal)
        } else {
            Text("清晰度: \(stream.qualityLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        if containsError(nsError, domain: "CoreMediaErrorDomain", code: -12881) {
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
            case .authRequired:
                code = "NB-PL-AUTH"
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
        guard let stream else {
            return false
        }

        let sampleURL: URL
        switch stream.transport {
        case .progressive(let url, _):
            sampleURL = url
        case .progressivePlaylist(let segments):
            guard let first = segments.first else {
                return false
            }
            sampleURL = first.url
        case .dash:
            return false
        }

        let format = stream.format.lowercased()
        let ext = sampleURL.pathExtension.lowercased()
        return format.contains("flv") || ext == "flv" || ext == "f4v"
    }

    private func buildTechnicalDetail(from nsError: NSError, stream: PlayableStream?) -> String {
        var details: [String] = [
            "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
        ]

        details.append("attempt_mode=\(lastAttemptedMode.rawValue)")
        details.append("attempt_index=\(retryAttemptIndex)")
        details.append("attempt_total=\(max(retryAttemptTotal, retryAttemptIndex))")
        details.append("retry_reason=\(retryReason.rawValue)")
        details.append("attempt_tag=\(lastAttemptReasonTag)")

        if let stream {
            switch stream.transport {
            case .progressive(let url, let fallbackURLs):
                details.append("stream=progressive format=\(stream.format)")
                details.append("url=\(url.absoluteString)")
                details.append("fallback_count=\(fallbackURLs.count)")
            case .progressivePlaylist(let segments):
                details.append("stream=progressive_playlist format=\(stream.format)")
                details.append("segment_count=\(segments.count)")
                if let firstURL = segments.first?.url {
                    details.append("first_url=\(firstURL.absoluteString)")
                }
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
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
        if let periodicTimeObserverToken {
            player.removeTimeObserver(periodicTimeObserverToken)
            self.periodicTimeObserverToken = nil
        }
    }

    @MainActor
    private func teardownPlayer() {
        player.pause()
        clearObservers()
        playbackItemFactory.releaseResources(for: player.currentItem)
        player.replaceCurrentItem(with: nil)
        lastAttemptedStream = nil
        resetRetryStateForFreshPlayback()
    }
}

private struct PlaybackDiagnostic {
    let code: String
    let userMessage: String
    let technicalDetail: String?
}

private struct PlaybackAttempt {
    let stream: PlayableStream
    let mode: PlaybackBuildMode
    let reasonTag: String
}

private enum PlaybackRetryReason: String {
    case compatibility = "compat"
    case nonCompatibility = "non_compat"
}

private struct FullScreenPlayerView: View {
    let player: AVPlayer

    var body: some View {
        FullScreenPlayerController(player: player)
            .ignoresSafeArea()
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
