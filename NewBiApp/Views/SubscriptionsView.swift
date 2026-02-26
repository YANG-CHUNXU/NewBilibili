import SwiftUI
import NewBiCore

struct SubscriptionsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: SubscriptionListViewModel
    @State private var sessdataInput = ""
    @State private var biliJctInput = ""
    @State private var cookieFeedback: String?
    @State private var cookieError: String?
    @State private var showQRLogin = false

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

            Section("B站登录态") {
                Text("手动输入需同时提供 SESSDATA 和 bili_jct。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("输入 SESSDATA", text: $sessdataInput)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("输入 bili_jct", text: $biliJctInput)
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

                Button("保存凭据") {
                    do {
                        try environment.importBilibiliCredential(
                            sessdataRaw: sessdataInput,
                            biliJctRaw: biliJctInput
                        )
                        sessdataInput = ""
                        biliJctInput = ""
                        cookieError = nil
                        cookieFeedback = "凭据已保存，双向同步已启用。"
                    } catch {
                        cookieFeedback = nil
                        cookieError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .disabled(
                    sessdataInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    biliJctInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Button("扫码登录") {
                    showQRLogin = true
                }

                Button("清除登录态", role: .destructive) {
                    environment.clearBilibiliCookie()
                    cookieFeedback = "已清除登录态。"
                    cookieError = nil
                }
                .disabled(!environment.bilibiliCookieConfigured)
            }

            Section("历史同步") {
                let overview = viewModel.historySyncOverview

                Text("上传队列：\(overview.pendingUploadCount)  删除队列：\(overview.pendingDeleteCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastSyncAt = overview.lastSyncAt {
                    Text("最近同步：\(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let nextRetryAt = overview.nextRetryAt {
                    Text("下次重试：\(nextRetryAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let statusMessage = overview.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(overview.isAuthRequired ? .orange : .secondary)
                }

                Button("立即同步") {
                    Task { await viewModel.triggerManualHistorySync() }
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
                        HStack(alignment: .top) {
                            Text(item.title)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Text(viewModel.syncLabel(for: item.bvid))
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }

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
        .sheet(isPresented: $showQRLogin) {
            QRLoginSheet(
                viewModel: QRLoginViewModel(
                    authClient: environment.biliAuthClient
                ) { credential in
                    try environment.importBilibiliCredentialFromQR(credential)
                    cookieFeedback = "扫码登录成功，已更新凭据。"
                    cookieError = nil
                }
            )
        }
    }
}
