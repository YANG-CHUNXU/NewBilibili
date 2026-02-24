import SwiftUI
import NewBiCore

struct SubscriptionsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: SubscriptionListViewModel
    @State private var sessdataInput: String = ""
    @State private var cookieFeedback: String?
    @State private var cookieError: String?

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

            Section("B站 SESSDATA（登录态）") {
                Text("只需要粘贴 SESSDATA 值；也支持粘贴 `SESSDATA=...`")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("输入 SESSDATA", text: $sessdataInput)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("状态：\(environment.bilibiliCookieStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let cookieFeedback {
                    Text(cookieFeedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let cookieError {
                    Text(cookieError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("保存 SESSDATA") {
                    do {
                        try environment.importBilibiliSessdata(sessdataInput)
                        sessdataInput = ""
                        cookieError = nil
                        cookieFeedback = "SESSDATA 已保存，将用于后续请求。"
                    } catch {
                        cookieFeedback = nil
                        cookieError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .disabled(sessdataInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("清除 Cookie", role: .destructive) {
                    environment.clearBilibiliCookie()
                    cookieFeedback = "已清除 Cookie。"
                    cookieError = nil
                }
                .disabled(!environment.bilibiliCookieConfigured)
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
