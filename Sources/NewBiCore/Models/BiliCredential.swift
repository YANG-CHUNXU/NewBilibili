import CryptoKit
import Foundation

public struct BiliCredential: Hashable, Codable, Sendable {
    public let sessdata: String
    public let biliJct: String?
    public let dedeUserID: String?
    public let updatedAt: Date

    public init(
        sessdata: String,
        biliJct: String?,
        dedeUserID: String?,
        updatedAt: Date
    ) {
        self.sessdata = sessdata
        self.biliJct = biliJct
        self.dedeUserID = dedeUserID
        self.updatedAt = updatedAt
    }

    public var canWriteHistory: Bool {
        guard let biliJct else {
            return false
        }
        return !biliJct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var accountCacheScope: String {
        if let normalizedDedeUserID = normalizedDedeUserID {
            return Self.fingerprint("uid:\(normalizedDedeUserID)")
        }
        return Self.fingerprint("sess:\(normalizedSessdata)")
    }

    private var normalizedSessdata: String {
        sessdata.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDedeUserID: String? {
        guard let dedeUserID else {
            return nil
        }
        let trimmed = dedeUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fingerprint(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return "fp:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
