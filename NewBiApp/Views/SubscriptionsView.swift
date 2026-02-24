import SwiftUI
import NewBiCore

struct SubscriptionsView: View {
    @StateObject private var viewModel: SubscriptionListViewModel

    init(viewModel: SubscriptionListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            Section("添加订阅") {
                TextField("输入 UID 或空间主页链接", text: $viewModel.newSubscriptionInput)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                Button("添加") {
                    Task { await viewModel.addSubscription() }
                }
                .disabled(viewModel.newSubscriptionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("已订阅") {
                if viewModel.subscriptions.isEmpty {
                    Text("暂无订阅")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UID: \(subscription.uid)")
                            .font(.headline)
                        Text(subscription.homepageURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    Task { await viewModel.removeSubscription(at: offsets) }
                }
            }

            Section("观看历史") {
                if viewModel.watchHistory.isEmpty {
                    Text("暂无历史")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.watchHistory) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text("BVID: \(item.bvid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("进度: \(Int(item.progressSeconds)) 秒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中...")
            }
        }
        .navigationTitle("订阅")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空历史") {
                    Task { await viewModel.clearHistory() }
                }
            }
        }
        .task {
            await viewModel.load()
        }
    }
}
