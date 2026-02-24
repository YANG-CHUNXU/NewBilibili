import Foundation
import NewBiCore

#if canImport(SwiftData)
import SwiftData

@available(iOS 17.0, *)
@MainActor
final class SwiftDataWatchHistoryRepository: WatchHistoryRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func list() async throws -> [WatchHistoryRecord] {
        let descriptor = FetchDescriptor<WatchHistoryEntity>(sortBy: [SortDescriptor(\.watchedAt, order: .reverse)])
        let entities = try modelContext.fetch(descriptor)
        return entities.map {
            WatchHistoryRecord(
                id: $0.id,
                bvid: $0.bvid,
                title: $0.title,
                watchedAt: $0.watchedAt,
                progressSeconds: $0.progressSeconds
            )
        }
    }

    func record(bvid: String, title: String, progressSeconds: Double) async throws {
        let entities = try modelContext.fetch(FetchDescriptor<WatchHistoryEntity>())
        if let existing = entities.first(where: { $0.bvid == bvid }) {
            existing.title = title
            existing.watchedAt = Date()
            existing.progressSeconds = progressSeconds
        } else {
            let entity = WatchHistoryEntity(
                id: UUID(),
                bvid: bvid,
                title: title,
                watchedAt: Date(),
                progressSeconds: progressSeconds
            )
            modelContext.insert(entity)
        }
        try modelContext.save()
    }

    func clear() async throws {
        let entities = try modelContext.fetch(FetchDescriptor<WatchHistoryEntity>())
        for entity in entities {
            modelContext.delete(entity)
        }
        try modelContext.save()
    }
}
#endif
