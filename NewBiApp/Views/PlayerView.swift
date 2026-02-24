import SwiftUI
import AVKit
import AVFoundation
import NewBiCore

struct PlayerView: View {
    @StateObject private var viewModel: PlayerViewModel
    @State private var player = AVPlayer()
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failedToEndObserver: NSObjectProtocol?
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
        self.playbackItemFactory = playbackItemFactory
    }

    var body: some View {
        VStack(spacing: 16) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if let stream = viewModel.stream {
                VideoPlayer(player: player)
                    .frame(minHeight: 220)
                    .task(id: stream) {
                        await preparePlayback(for: stream)
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
        .onDisappear {
            let seconds = player.currentTime().seconds
            Task {
                await viewModel.recordPlayback(progressSeconds: seconds.isFinite ? seconds : 0)
            }
            teardownPlayer()
        }
    }

    @MainActor
    private func preparePlayback(for stream: PlayableStream) async {
        do {
            let item = try await playbackItemFactory.makePlayerItem(from: stream)
            bindFailureObservers(to: item)
            playbackItemFactory.releaseResources(for: player.currentItem)
            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            viewModel.reportPlaybackError(error)
        }
    }

    @MainActor
    private func bindFailureObservers(to item: AVPlayerItem) {
        clearObservers()

        let model = viewModel
        statusObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
            guard observedItem.status == .failed else {
                return
            }
            let err = observedItem.error ?? BiliClientError.playbackProxyFailed("播放器加载失败")
            Task { @MainActor in
                model.reportPlaybackError(err)
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
                model.reportPlaybackError(err)
            }
        }
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
    }
}
