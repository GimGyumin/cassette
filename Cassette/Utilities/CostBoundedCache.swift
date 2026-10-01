// Cassette - Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.

/// Actor-owned LRU storage with hard entry and decoded-memory limits.
nonisolated struct CostBoundedCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
    }

    let countLimit: Int
    let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var accessOrder: [Key] = []
    private(set) var totalCost = 0

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = max(0, countLimit)
        self.costLimit = max(0, costLimit)
    }

    var count: Int { entries.count }

    /// A peek does not change eviction order.
    subscript(key: Key) -> Value? { entries[key]?.value }

    mutating func value(forKey key: Key) -> Value? {
        guard let value = entries[key]?.value else { return nil }
        touch(key)
        return value
    }

    mutating func touch(_ key: Key) {
        guard entries[key] != nil else { return }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    mutating func insert(_ value: Value, forKey key: Key, cost: Int) {
        removeValue(forKey: key)
        let cost = max(0, cost)
        // An oversized image is still returned to its caller, but must not flush the cache.
        guard countLimit > 0, costLimit > 0, cost <= costLimit else { return }
        while entries.count >= countLimit || totalCost > costLimit - cost {
            guard let oldest = accessOrder.first else { break }
            removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, cost: cost)
        totalCost += cost
        accessOrder.append(key)
    }

    mutating func removeValue(forKey key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        accessOrder.removeAll { $0 == key }
    }

    mutating func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
        totalCost = 0
    }
}
