import Foundation

/// Account-owned metadata cache. Cost is a caller-defined record count, not a measured
/// byte estimate. Oversized responses are returned normally but not retained.
nonisolated struct ExpiringBoundedCache<Key: Hashable, Value> {
    private struct Entry { let value: Value; let expires: TimeInterval }
    private var storage: CostBoundedCache<Key, Entry>
    private let lifetime: TimeInterval
    var count: Int { storage.count }
    var totalCost: Int { storage.totalCost }

    init(countLimit: Int, costLimit: Int, lifetime: TimeInterval) {
        storage = CostBoundedCache(countLimit: countLimit, costLimit: costLimit)
        self.lifetime = max(0, lifetime)
    }

    mutating func value(forKey key: Key, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Value? {
        guard let entry = storage.value(forKey: key) else { return nil }
        guard now < entry.expires else { storage.removeValue(forKey: key); return nil }
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: Key, cost: Int,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        storage.insert(Entry(value: value, expires: now + lifetime), forKey: key, cost: cost)
    }

    mutating func removeAll() { storage.removeAll() }
}
