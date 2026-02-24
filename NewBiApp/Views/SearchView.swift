import SwiftUI
import NewBiCore

struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    private let biliClient: any BiliPublicClient
    private let historyRepository: any WatchHistoryRepository
    private let playbackItemFactory: any PlaybackItemFactoryProtocol

    init(
        viewModel: SearchViewModel,
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
            Section {
                TextField("输入关键词", text: $viewModel.keyword)
                    .textInputAutocapitalization(.never)

                Picker("页码", selection: $viewModel.page) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)

                Button("搜索") {
                    Task { await viewModel.search() }
                }
                .disabled(viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                ForEach(viewModel.results) { video in
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
                ProgressView("搜索中...")
            }
        }
        .navigationTitle("搜索")
    }
}
