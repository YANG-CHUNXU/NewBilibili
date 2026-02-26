import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import NewBiCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class QRLoginViewModel: ObservableObject {
    @Published private(set) var qrImage: Image?
    @Published private(set) var statusText: String = "点击“刷新二维码”开始登录"
    @Published private(set) var errorText: String?
    @Published private(set) var isLoading = false

    private let authClient: any BiliAuthClient
    private let didReceiveCredential: (BiliCredential) throws -> Void
    private let context = CIContext()
    private var pollTask: Task<Void, Never>?

    init(
        authClient: any BiliAuthClient,
        didReceiveCredential: @escaping (BiliCredential) throws -> Void
    ) {
        self.authClient = authClient
        self.didReceiveCredential = didReceiveCredential
    }

    deinit {
        pollTask?.cancel()
    }

    func refreshQRCode() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.loadQRCodeAndPoll()
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadQRCodeAndPoll() async {
        isLoading = true
        errorText = nil
        statusText = "正在生成二维码..."

        do {
            let session = try await authClient.createQRCodeSession()
            qrImage = makeQRImage(from: session.loginURL.absoluteString)
            statusText = "请使用 B 站 App 扫码并确认登录"
            isLoading = false
            try await pollLoginStatus(qrcodeKey: session.qrcodeKey)
        } catch {
            isLoading = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = "二维码生成失败"
        }
    }

    private func pollLoginStatus(qrcodeKey: String) async throws {
        while !Task.isCancelled {
            do {
                let state = try await authClient.pollQRCodeStatus(qrcodeKey: qrcodeKey)
                switch state {
                case .waitingScan:
                    statusText = "等待扫码"
                case .waitingConfirm:
                    statusText = "已扫码，等待确认"
                case .expired:
                    statusText = "二维码已过期，请刷新"
                    return
                case .confirmed(let credential):
                    try didReceiveCredential(credential)
                    statusText = "登录成功，已导入凭据"
                    errorText = nil
                    return
                }
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                statusText = "轮询失败，请刷新二维码"
                return
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func makeQRImage(from text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return nil
        }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #else
        return nil
        #endif
    }
}

struct QRLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: QRLoginViewModel

    init(viewModel: QRLoginViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let qrImage = viewModel.qrImage {
                        qrImage
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay {
                                Text("暂无二维码")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(maxWidth: 260, maxHeight: 260)

                if viewModel.isLoading {
                    ProgressView("加载中...")
                }

                Text(viewModel.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorText = viewModel.errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("刷新二维码") {
                        viewModel.refreshQRCode()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("关闭") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                viewModel.refreshQRCode()
            }
            .onDisappear {
                viewModel.stopPolling()
            }
        }
    }
}
