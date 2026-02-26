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
}
