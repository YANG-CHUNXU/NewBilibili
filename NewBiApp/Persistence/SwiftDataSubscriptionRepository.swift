import Foundation
import NewBiCore

#if canImport(SwiftData)
import SwiftData

@available(iOS 17.0, *)
@MainActor
final class SwiftDataSubscriptionRepository: SubscriptionRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func list() async throws -> [Subscription] {
        let descriptor = FetchDescriptor<SubscriptionEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let entities = try modelContext.fetch(descriptor)
        return entities.compactMap { entity in
            guard let url = URL(string: entity.homepageURLString) else {
                return nil
            }
            return Subscription(id: entity.id, uid: entity.uid, homepageURL: url, createdAt: entity.createdAt)
        }
    }

    func add(input: String) async throws -> Subscription {
        let uid = try SubscriptionInputNormalizer.normalizeUID(from: input)
        let existing = try modelContext.fetch(FetchDescriptor<SubscriptionEntity>()).first(where: { $0.uid == uid })
        if let existing, let url = URL(string: existing.homepageURLString) {
            return Subscription(id: existing.id, uid: existing.uid, homepageURL: url, createdAt: existing.createdAt)
        }

        let id = UUID()
        let homepage = URL(string: "https://space.bilibili.com/\(uid)")!
        let entity = SubscriptionEntity(
            id: id,
            uid: uid,
            homepageURLString: homepage.absoluteString,
            createdAt: Date()
        )

        modelContext.insert(entity)
        try modelContext.save()

        return Subscription(id: id, uid: uid, homepageURL: homepage, createdAt: entity.createdAt)
    }

    func remove(id: UUID) async throws {
        let entities = try modelContext.fetch(FetchDescriptor<SubscriptionEntity>())
        guard let entity = entities.first(where: { $0.id == id }) else {
            return
        }
        modelContext.delete(entity)
        try modelContext.save()
    }
}
#endif
