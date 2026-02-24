import Foundation
import NewBiCore

actor FileSubscriptionRepository: SubscriptionRepository {
    private let fileURL: URL
    private var cache: [Subscription]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.cache = []
        self.cache = (try? Self.load(url: fileURL, decoder: decoder)) ?? []
    }

    func list() async throws -> [Subscription] {
        cache.sorted { $0.createdAt > $1.createdAt }
    }

    func add(input: String) async throws -> Subscription {
        let uid = try SubscriptionInputNormalizer.normalizeUID(from: input)
        if let existing = cache.first(where: { $0.uid == uid }) {
            return existing
        }

        let subscription = Subscription(
            id: UUID(),
            uid: uid,
            homepageURL: URL(string: "https://space.bilibili.com/\(uid)")!,
            createdAt: Date()
        )
        cache.append(subscription)
        try persist()
        return subscription
    }

    func remove(id: UUID) async throws {
        cache.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(url: URL, decoder: JSONDecoder) throws -> [Subscription] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([Subscription].self, from: data)
    }
}
