import SwiftUI
import AVKit
import NewBiCore

struct PlayerView: View {
    @StateObject private var viewModel: PlayerViewModel
    @State private var player = AVPlayer()

    init(
        bvid: String,
        cid: Int?,
        title: String,
        biliClient: any BiliPublicClient,
        historyRepository: any WatchHistoryRepository
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
                    .onAppear {
                        let item = AVPlayerItem(url: stream.url)
                        player.replaceCurrentItem(with: item)
                        player.play()
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
            player.pause()
        }
    }
}
