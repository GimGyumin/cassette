import Testing
@testable import Cassette

@Suite("CostBoundedCache")
struct CostBoundedCacheTests {
    @Test("Byte budget evicts the least recently used entry")
    func costLimitUsesLRU() {
        var cache = CostBoundedCache<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.insert(2, forKey: "b", cost: 40)
        #expect(cache.value(forKey: "a") == 1)
        cache.insert(3, forKey: "c", cost: 40)
        #expect(cache["a"] == 1)
        #expect(cache["b"] == nil)
        #expect(cache["c"] == 3)
        #expect(cache.totalCost == 80)
    }

    @Test("Entry count is bounded even for small images")
    func countLimit() {
        var cache = CostBoundedCache<Int, Int>(countLimit: 2, costLimit: 100)
        for i in 0..<100 { cache.insert(i, forKey: i, cost: 1) }
        #expect(cache.count == 2)
        #expect(cache.totalCost == 2)
        #expect(cache[98] == 98)
        #expect(cache[99] == 99)
    }

    @Test("Replacement accounts for the old cost exactly once")
    func replacementAndRemoval() {
        var cache = CostBoundedCache<String, Int>(countLimit: 3, costLimit: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.insert(2, forKey: "a", cost: 80)
        #expect(cache.totalCost == 80)
        #expect(cache.count == 1)
        cache.removeValue(forKey: "a")
        cache.removeValue(forKey: "a")
        #expect(cache.totalCost == 0)
        #expect(cache.count == 0)
    }

    @Test("Oversized items do not discard unrelated cached images")
    func oversizedItem() {
        var cache = CostBoundedCache<String, Int>(countLimit: 3, costLimit: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.insert(2, forKey: "large", cost: 101)
        #expect(cache["a"] == 1)
        #expect(cache["large"] == nil)
        #expect(cache.totalCost == 40)
    }

    @Test("Memory pressure clears values and accounting; the cache can be reused")
    func clearAndReuse() {
        var cache = CostBoundedCache<String, Int>(countLimit: 2, costLimit: 100)
        cache.insert(1, forKey: "a", cost: 40)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        cache.insert(2, forKey: "b", cost: 100)
        #expect(cache["b"] == 2)
        #expect(cache.totalCost == 100)
    }

    @Test("Zero or negative budgets disable caching")
    func disabledCache() {
        var cache = CostBoundedCache<Int, Int>(countLimit: -1, costLimit: 100)
        cache.insert(1, forKey: 1, cost: 1)
        #expect(cache.count == 0)
        var noMemory = CostBoundedCache<Int, Int>(countLimit: 10, costLimit: 0)
        noMemory.insert(1, forKey: 1, cost: 0)
        #expect(noMemory.count == 0)
    }

    @Test("Mixed hero and thumbnail traffic never exceeds either limit")
    func mixedArtworkStress() {
        var cache = CostBoundedCache<Int, Int>(countLimit: 110, costLimit: 48 * 1024 * 1024)
        for i in 0..<10_000 {
            let pixels = i.isMultiple(of: 3) ? 1200 : 240
            cache.insert(i, forKey: i % 200, cost: pixels * pixels * 4)
            #expect(cache.totalCost <= cache.costLimit)
            #expect(cache.count <= cache.countLimit)
        }
    }
}
