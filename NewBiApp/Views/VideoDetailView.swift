import SwiftUI
import NewBiCore

struct VideoDetailView: View {
    @StateObject private var viewModel: VideoDetailViewModel
    private let initialTitle: String
    private let biliClient: any BiliPublicClient
    private let historyRepository: any WatchHistoryRepository

    init(
        bvid: String,
        initialTitle: String,
        biliClient: any BiliPublicClient,
        historyRepository: any WatchHistoryRepository
    ) {
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(bvid: bvid, biliClient: biliClient))
        self.initialTitle = initialTitle
        self.biliClient = biliClient
        self.historyRepository = historyRepository
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            if let detail = viewModel.detail {
                Section("基础信息") {
                    Text(detail.title)
                        .font(.headline)
                    Text("UP: \(detail.authorName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let description = detail.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                    }
                }

                Section("公开统计") {
                    if let stats = detail.stats {
                        StatLine(name: "播放", value: stats.view)
                        StatLine(name: "点赞", value: stats.like)
                        StatLine(name: "投币", value: stats.coin)
                        StatLine(name: "收藏", value: stats.favorite)
                        StatLine(name: "评论", value: stats.reply)
                        StatLine(name: "弹幕", value: stats.danmaku)
                        StatLine(name: "分享", value: stats.share)
                    } else {
                        Text("暂无统计信息")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("分 P") {
                    if detail.parts.isEmpty {
                        NavigationLink("播放") {
                            PlayerView(
                                bvid: detail.bvid,
                                cid: nil,
                                title: detail.title,
                                biliClient: biliClient,
                                historyRepository: historyRepository
                            )
                        }
                    } else {
                        ForEach(detail.parts, id: \.cid) { part in
                            NavigationLink {
                                PlayerView(
                                    bvid: detail.bvid,
                                    cid: part.cid,
                                    title: "\(detail.title) - \(part.title)",
                                    biliClient: biliClient,
                                    historyRepository: historyRepository
                                )
                            } label: {
                                HStack {
                                    Text("P\(part.page) \(part.title)")
                                    Spacer()
                                    if let duration = part.durationSeconds {
                                        Text("\(duration)秒")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载详情...")
            }
        }
        .navigationTitle(viewModel.detail?.title ?? initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
    }
}

private struct StatLine: View {
    let name: String
    let value: Int?

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(value.map(String.init) ?? "-")
                .foregroundStyle(.secondary)
        }
    }
}
