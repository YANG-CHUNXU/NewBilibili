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
                progressSeconds: $0.progressSeconds,
                cid: $0.cid
            )
        }
    }

    func record(
        bvid: String,
        title: String,
        progressSeconds: Double,
        watchedAt: Date?,
        cid: Int?
    ) async throws {
        let now = watchedAt ?? Date()
        let entities = try modelContext.fetch(FetchDescriptor<WatchHistoryEntity>())
        if let existing = entities.first(where: { $0.bvid == bvid }) {
            existing.title = title
            existing.watchedAt = now
            existing.progressSeconds = progressSeconds
            if let cid {
                existing.cid = cid
            }
        } else {
            let entity = WatchHistoryEntity(
                id: UUID(),
                bvid: bvid,
                title: title,
                watchedAt: now,
                progressSeconds: progressSeconds,
                cid: cid
            )
            modelContext.insert(entity)
        }
        try modelContext.save()
    }

    func remove(bvid: String) async throws {
        let entities = try modelContext.fetch(FetchDescriptor<WatchHistoryEntity>())
        if let existing = entities.first(where: { $0.bvid == bvid }) {
            modelContext.delete(existing)
            try modelContext.save()
        }
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
