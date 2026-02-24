import Foundation

public struct Subscription: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let uid: String
    public let homepageURL: URL
    public let createdAt: Date

    public init(id: UUID, uid: String, homepageURL: URL, createdAt: Date) {
        self.id = id
        self.uid = uid
        self.homepageURL = homepageURL
        self.createdAt = createdAt
    }
}
