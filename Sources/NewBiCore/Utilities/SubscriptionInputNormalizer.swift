import Foundation

public enum SubscriptionInputNormalizer {
    public static func normalizeUID(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BiliClientError.invalidInput("请输入 UID 或空间主页链接")
        }

        if isUID(trimmed) {
            return trimmed
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased()
        else {
            throw BiliClientError.invalidInput("无法识别 UID 或链接")
        }

        if host.contains("space.bilibili.com") {
            let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if let first = components.first, isUID(first) {
                return first
            }
        }

        throw BiliClientError.invalidInput("仅支持 UID 或 space.bilibili.com/{uid} 链接")
    }

    private static func isUID(_ text: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    }
}
