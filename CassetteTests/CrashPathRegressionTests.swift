// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Synchronization
import Testing
@testable import Cassette

@Suite("October crash path regressions")
struct CrashPathRegressionTests {
    @Test func waitingNotificationsCannotReissuePromptWithoutClockProgress() {
        var gate = PromptPlaybackGate()
        gate.reset(armed: true)
        let initial = gate.consume(position: 0)
        #expect(initial)
        for _ in 0..<3_321 {
            // Even a transient playing/waiting pair from playImmediately must not
            // permit another command on the same buffer acquisition.
            gate.didStartPlaying()
            gate.armForRecovery(position: 0)
            let repeated = gate.consume(position: 0)
            #expect(!repeated)
        }
        gate.armForRecovery(position: 10)
        let recovery = gate.consume(position: 10)
        #expect(recovery)
        gate.armForRecovery(position: 10)
        let repeatedRecovery = gate.consume(position: 10)
        #expect(!repeatedRecovery)
        // Explicit seek/new item permits startup at an earlier media time.
        gate.reset(armed: true)
        let afterSeek = gate.consume(position: 2)
        #expect(afterSeek)
        gate.reset(armed: false)
        let afterStop = gate.consume(position: 2)
        #expect(!afterStop)
    }

    @Test func palettePersistenceObserversCanReadAndUpdateTheCache() async throws {
        let cacheRef = Mutex<ArtworkPaletteCache?>(nil)
        let observerReadSucceeded = Mutex(false)
        let writes = Mutex<[[String: Data]]>([])
        let palette = Self.palette(0x123456)
        let changed = Self.palette(0x654321)
        let cache = ArtworkPaletteCache(load: { [:] }, persist: { snapshot in
            writes.withLock { $0.append(snapshot) }
            // Model an observer waiting for another thread (e.g. SwiftUI) to
            // read the cache before UserDefaults.set returns. Bound the wait so
            // a lock regression reports a failure instead of hanging the suite.
            if writes.withLock({ $0.count }) == 1 {
                let readFinished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    let cache = cacheRef.withLock { $0 }
                    observerReadSucceeded.withLock { $0 = cache?.palette(for: "cover") == palette }
                    cache?.store(changed, for: "cover")
                    readFinished.signal()
                }
                #expect(readFinished.wait(timeout: .now() + 2) == .success)
            }
        })
        cacheRef.withLock { $0 = cache }
        defer { cacheRef.withLock { $0 = nil } }
        cache.store(palette, for: "cover")
        await cache.flush()
        #expect(observerReadSucceeded.withLock { $0 })
        await cache.flush()
        let snapshots = writes.withLock { $0 }
        #expect(snapshots.count == 2)
        let data = try #require(snapshots.last?["cover"])
        #expect(try JSONDecoder().decode(ColorCache.CachedPalette.self, from: data) == changed)
        // A clean flush and storing the same palette cause no additional writes.
        cache.store(changed, for: "cover")
        await cache.flush()
        #expect(writes.withLock { $0.count } == 2)
    }

    @Test func coldHydrationDoesNotHoldTheCacheLockOrUndoAClear() throws {
        let cacheRef = Mutex<ArtworkPaletteCache?>(nil)
        let data = try JSONEncoder().encode(Self.palette(0x123456))
        let cache = ArtworkPaletteCache(load: {
            let readFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                cacheRef.withLock { $0 }?.clear()
                readFinished.signal()
            }
            #expect(readFinished.wait(timeout: .now() + 2) == .success)
            return ["old": data]
        }, persist: { _ in })
        cacheRef.withLock { $0 = cache }
        defer { cacheRef.withLock { $0 = nil } }
        #expect(cache.palette(for: "old") == nil)
    }

    @Test func hydrationAndClearPreserveTheStoredFormatAndCoalesceWrites() async throws {
        let writes = Mutex<[[String: Data]]>([])
        let palette = Self.palette(0x123456)
        let data = try JSONEncoder().encode(palette)
        let cache = ArtworkPaletteCache(load: { ["cover": data] }, persist: { snapshot in
            writes.withLock { $0.append(snapshot) }
        })
        cache.store(palette, for: "cover")
        #expect(cache.palette(for: "cover") == palette)
        await cache.flush()
        #expect(writes.withLock { $0.isEmpty })
        for index in 0..<100 { cache.store(palette, for: "cover-\(index)") }
        cache.clear()
        await cache.flush()
        // Includes cancellation of all delayed snapshots queued before clear.
        try await Task.sleep(for: .milliseconds(650))
        #expect(writes.withLock { $0.count } == 1)
        #expect(writes.withLock { $0.last?.isEmpty } == true)
        #expect(cache.palette(for: "cover") == nil)
    }

    private static func palette(_ background: Int) -> ColorCache.CachedPalette {
        .init(packedBackground: background, packedText1: 0xffffff,
              packedText2: 0xdddddd, packedText3: 0xbbbbbb, packedText4: 0x999999)
    }
}
