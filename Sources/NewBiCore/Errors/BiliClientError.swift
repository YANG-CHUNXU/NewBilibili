import Foundation

public enum BiliClientError: LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case networkFailed(String)
    case parseFailed(String)
    case noPlayableStream
    case rateLimited
    case authRequired(String)
    case playbackProxyFailed(String)
    case unsupportedDashStream(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let reason):
            return "输入无效：\(reason)"
        case .networkFailed(let reason):
            return "网络请求失败：\(reason)"
        case .parseFailed(let reason):
            return "页面解析失败：\(reason)"
        case .noPlayableStream:
            return "未找到可直接播放的视频流"
        case .rateLimited:
            return "请求过于频繁或触发风控（如 code -352），建议在“我的”页导入 SESSDATA 并稍后重试"
        case .authRequired(let reason):
            return "登录状态失效：\(reason)"
        case .playbackProxyFailed(let reason):
            return "播放器代理失败：\(reason)"
        case .unsupportedDashStream(let reason):
            return "不支持的 DASH 流：\(reason)"
        }
    }
}
