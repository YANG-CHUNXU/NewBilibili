import Foundation

public actor VideoCardMemoryCache {
    private struct CacheEntry {
        let createdAt: Date
        let value: [VideoCard]
    }

    private let ttl: TimeInterval
    private var storage: [String: CacheEntry] = [:]

    public init(ttl: TimeInterval = 600) {
        self.ttl = ttl
    }

    public func get(_ key: String) -> [VideoCard]? {
        guard let entry = storage[key] else {
            return nil
        }

        if Date().timeIntervalSince(entry.createdAt) > ttl {
            storage.removeValue(forKey: key)
            return nil
        }

        return entry.value
    }

    public func set(_ key: String, value: [VideoCard]) {
        storage[key] = CacheEntry(createdAt: Date(), value: value)
    }

    public func clear() {
        storage.removeAll()
    }
}
