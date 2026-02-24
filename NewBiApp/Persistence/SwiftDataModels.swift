import Foundation

#if canImport(SwiftData)
import SwiftData

@available(iOS 17.0, *)
@Model
final class SubscriptionEntity {
    @Attribute(.unique) var uid: String
    var id: UUID
    var homepageURLString: String
    var createdAt: Date

    init(id: UUID, uid: String, homepageURLString: String, createdAt: Date) {
        self.id = id
        self.uid = uid
        self.homepageURLString = homepageURLString
        self.createdAt = createdAt
    }
}

@available(iOS 17.0, *)
@Model
final class WatchHistoryEntity {
    @Attribute(.unique) var bvid: String
    var id: UUID
    var title: String
    var watchedAt: Date
    var progressSeconds: Double

    init(id: UUID, bvid: String, title: String, watchedAt: Date, progressSeconds: Double) {
        self.id = id
        self.bvid = bvid
        self.title = title
        self.watchedAt = watchedAt
        self.progressSeconds = progressSeconds
    }
}

@available(iOS 17.0, *)
enum NewBiModelContainerFactory {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SubscriptionEntity.self,
            WatchHistoryEntity.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
#endif
