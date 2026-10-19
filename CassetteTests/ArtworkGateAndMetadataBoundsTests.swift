import Foundation
import Testing
@testable import Cassette

struct ArtworkGateAndMetadataBoundsTests {
    @Test func cancelledWaiterFinishesWithoutWaitingForTheBusySlot() async throws {
        let gate = CoverDecodeGate(limit: 1)
        #expect(await gate.acquire())
        let waiter = Task { await gate.acquire() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await gate.waitingCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.waitingCount == 1)
        waiter.cancel()
        #expect(!(await waiter.value))
        #expect(await gate.waitingCount == 0)
        await gate.release()
        #expect(await gate.acquire())
        await gate.release()
    }

    @Test func cancelledTaskDoesNotConsumeAnAvailablePermit() async {
        let gate = CoverDecodeGate(limit: 1)
        let held = HeldAuditResult<Bool>()
        var starts = held.starts.makeAsyncIterator()
        let task = Task {
            _ = await held.value()
            return await gate.acquire()
        }
        _ = await starts.next()
        task.cancel()
        held.finish(true)
        #expect(!(await task.value))
        #expect(await gate.acquire())
        await gate.release()
    }

    @Test func metadataRetentionIsBoundedAndExpiresWithoutClockChanges() {
        var cache = ExpiringBoundedCache<String, Int>(countLimit: 2, costLimit: 4, lifetime: 10)
        cache.insert(1, forKey: "one", cost: 2, now: 0)
        cache.insert(2, forKey: "two", cost: 2, now: 0)
        #expect(cache.value(forKey: "one", now: 1) == 1)
        cache.insert(3, forKey: "three", cost: 2, now: 1)
        #expect(cache.value(forKey: "two", now: 2) == nil)
        #expect(cache.count == 2)
        #expect(cache.totalCost == 4)
        cache.insert(99, forKey: "oversized", cost: 5, now: 2)
        #expect(cache.count == 2)
        #expect(cache.value(forKey: "oversized", now: 2) == nil)
        #expect(cache.value(forKey: "one", now: 10) == nil)
        cache.removeAll()
        #expect(cache.count == 0 && cache.totalCost == 0)
    }
}
