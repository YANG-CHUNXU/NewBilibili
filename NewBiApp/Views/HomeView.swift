import SwiftUI
import NewBiCore

struct HomeView: View {
    @StateObject private var viewModel: HomeFeedViewModel
    private let biliClient: any BiliPublicClient
    private let historyRepository: any WatchHistoryRepository
    private let playbackItemFactory: any PlaybackItemFactoryProtocol

    init(
        viewModel: HomeFeedViewModel,
        biliClient: any BiliPublicClient,
        historyRepository: any WatchHistoryRepository,
        playbackItemFactory: any PlaybackItemFactoryProtocol
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.biliClient = biliClient
        self.historyRepository = historyRepository
        self.playbackItemFactory = playbackItemFactory
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            if viewModel.videos.isEmpty, !viewModel.isLoading {
                Section {
                    Text("暂无内容，请先在订阅页添加 UP 主")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(viewModel.videos) { video in
                    NavigationLink {
                        VideoDetailView(
                            bvid: video.bvid,
                            initialTitle: video.title,
                            biliClient: biliClient,
                            historyRepository: historyRepository,
                            playbackItemFactory: playbackItemFactory
                        )
                    } label: {
                        VideoCardRow(video: video)
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中...")
            }
        }
        .navigationTitle("订阅聚合")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") {
                    Task { await viewModel.load(force: true) }
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load(force: true)
        }
    }
}

struct VideoCardRow: View {
    let video: VideoCard

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: atsSafeImageURL(video.coverURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Color.gray.opacity(0.2)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .lineLimit(2)
                    .font(.headline)

                Text(video.authorName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    if let duration = video.durationText {
                        Text(duration)
                    }
                    if let publishTime = video.publishTime {
                        Text(publishTime.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func atsSafeImageURL(_ url: URL?) -> URL? {
        guard let url else {
            return nil
        }
        guard url.scheme?.lowercased() == "http" else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }
}
