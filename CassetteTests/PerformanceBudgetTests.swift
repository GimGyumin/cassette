import Testing
import Foundation
@testable import Cassette

/// The battery / thermal policy is a pure function, so it is tested as one: no device, no
/// `ProcessInfo` stubbing, no timing. `ThermalHysteresis` takes an injected clock for the same
/// reason.
@Suite("PerformanceBudget")
struct PerformanceBudgetTests {
    private func budget(
        thermal: ThermalPressure = .nominal,
        lowPower: Bool = false,
        active: Bool = true,
        reduceMotion: Bool = false,
        memory: Bool = false,
        glassOverride: Bool = false
    ) -> PerformanceBudget {
        .make(
            thermalPressure: thermal,
            isLowPowerMode: lowPower,
            isAppActive: active,
            reduceMotion: reduceMotion,
            isMemoryPressured: memory,
            liquidGlassOverride: glassOverride
        )
    }

    @Test("A cool, foreground, full-power device keeps every optional feature")
    func nominalKeepsFeatures() {
        let b = budget()
        #expect(b.allowsDecorativeMotion)
        #expect(b.allowsBeatVisuals)
        #expect(b.allowsHeavyColorAnalysis)
        #expect(b.allowsArtworkPrefetch)
        #expect(b.artworkPrefetchBatchSize == 3)
        #expect(b.artworkPrefetchPause == nil)
        #expect(b.meshFrameInterval == 1.0 / 12.0)
        #expect(b.beatPublishInterval == 0.25)
        #expect(b.lyricsTickIntervalNs(karaokePlayback: true) == 16_666_666)
        #expect(b.lyricsTickIntervalNs(karaokePlayback: false) == 33_333_333)
        // Flat chrome is the shipping default; Liquid Glass is a QA override.
        #expect(b.prefersCheapChrome)
        // Gapless pre-buffering is a core playback behaviour, so it stays on here.
        #expect(b.allowsGaplessPrebuffer)
    }

    @Test("Low Power Mode sheds motion, analysis and prefetch speed")
    func lowPowerDegrades() {
        let b = budget(lowPower: true)
        #expect(!b.allowsDecorativeMotion)
        #expect(!b.allowsBeatVisuals)
        #expect(!b.allowsHeavyColorAnalysis)
        #expect(b.artworkPrefetchBatchSize == 1)
        #expect(b.artworkPrefetchPause != nil)
        #expect(b.beatPublishInterval == 0.40)
        #expect(b.meshFrameInterval == 1.0 / 8.0)
        #expect(b.lyricsTickIntervalNs(karaokePlayback: true) == 33_333_333)
        #expect(b.lyricsTickIntervalNs(karaokePlayback: false) == 50_000_000)
        #expect(b.prefersCheapChrome)
        // Deliberate: Low Power Mode must not cost the user gapless playback (it is a listening
        // behaviour, not decoration) — the bridge usually reads an already-cached file.
        #expect(b.allowsGaplessPrebuffer)
    }

    @Test("Thermal pressure escalates only when the device is throttling")
    func thermalEscalation() {
        let fair = budget(thermal: .fair)
        // `fair` is "warm, still fine": visuals stay, background work slows down.
        #expect(fair.allowsDecorativeMotion)
        #expect(fair.allowsBeatVisuals)
        #expect(fair.allowsHeavyColorAnalysis)
        #expect(fair.artworkPrefetchBatchSize == 2)

        let serious = budget(thermal: .serious)
        #expect(!serious.allowsDecorativeMotion)
        #expect(!serious.allowsBeatVisuals)
        #expect(!serious.allowsHeavyColorAnalysis)
        // Prefetch is paced, not stopped: a long download still finishes, just gently.
        #expect(serious.artworkPrefetchBatchSize == 1)
        #expect(serious.artworkPrefetchPause != nil)
        #expect(serious.allowsArtworkPrefetch)

        let critical = budget(thermal: .critical)
        #expect(!critical.allowsDecorativeMotion)
        #expect(!critical.allowsArtworkPrefetch)
        #expect(critical.artworkPrefetchPause != nil)
        // Pre-buffering the next track is exactly what a thermally critical device must not do.
        #expect(!critical.allowsGaplessPrebuffer)
    }

    @Test("Background stops decoration but preserves continuous audio")
    func backgroundIsFree() {
        let b = budget(active: false)
        #expect(!b.allowsDecorativeMotion)
        #expect(!b.allowsBeatVisuals)
        #expect(!b.allowsHeavyColorAnalysis)
        #expect(!b.allowsArtworkPrefetch)
        #expect(b.prefersCheapChrome)
        #expect(b.allowsGaplessPrebuffer)
    }

    @Test("Reduce Motion removes decoration but not background work")
    func reduceMotionKeepsBackgroundWork() {
        let b = budget(reduceMotion: true)
        #expect(!b.allowsDecorativeMotion)
        #expect(!b.allowsBeatVisuals)
        // A user preference must not silently disable downloads or themes.
        #expect(b.allowsHeavyColorAnalysis)
        #expect(b.allowsArtworkPrefetch)
        #expect(b.artworkPrefetchBatchSize == 3)
    }

    @Test("Memory pressure stops the heaviest work first")
    func memoryPressureDegradesHeavyWork() {
        let b = budget(memory: true)
        #expect(!b.allowsHeavyColorAnalysis)
        #expect(!b.allowsBeatVisuals)
        #expect(!b.allowsArtworkPrefetch)
        // Decoration is cheap compared to a re-analysis; it stays.
        #expect(b.allowsDecorativeMotion)
        #expect(!b.allowsGaplessPrebuffer)
    }

    @Test("Liquid Glass QA override never wins on a hot or power-saving device")
    func glassOverrideRespectsDevice() {
        #expect(!budget(glassOverride: true).prefersCheapChrome)
        #expect(budget(lowPower: true, glassOverride: true).prefersCheapChrome)
        #expect(budget(thermal: .serious, glassOverride: true).prefersCheapChrome)
        #expect(budget(active: false, glassOverride: true).prefersCheapChrome)
    }

    @Test("Thermal buckets map from ProcessInfo and split at serious")
    func thermalMapping() {
        #expect(ThermalPressure(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(ThermalPressure(ProcessInfo.ThermalState.fair) == .fair)
        #expect(ThermalPressure(ProcessInfo.ThermalState.serious) == .serious)
        #expect(ThermalPressure(ProcessInfo.ThermalState.critical) == .critical)
        #expect(ThermalPressure.fair < .serious)
        #expect(!ThermalPressure.fair.requiresBackOff)
        #expect(ThermalPressure.serious.requiresBackOff)
        #expect(ThermalPressure.critical.requiresBackOff)
    }
}

/// Recovery is deliberately slower than degradation: a device sitting on a thermal boundary must
/// not flip the UI between "animated" and "flat" every few seconds.
@Suite("ThermalHysteresis")
struct ThermalHysteresisTests {
    @Test("Escalation applies immediately")
    func escalatesImmediately() {
        var latch = ThermalHysteresis(restoreDelay: 20)
        let hot = latch.update(observed: .serious, now: 0)
        #expect(hot.pressure == .serious)
        #expect(!hot.needsRestoreRecheck)
        // Even a cooler reading one second later cannot restore the expensive policy yet.
        let cooling = latch.update(observed: .nominal, now: 1)
        #expect(cooling.pressure == .serious)
        #expect(cooling.needsRestoreRecheck)
    }

    @Test("Restore waits out the cool-down window")
    func restoresAfterDelay() {
        var latch = ThermalHysteresis(restoreDelay: 20)
        _ = latch.update(observed: .critical, now: 0)
        // The cool-down window starts at the first cooler reading (t = 5), not at the heat peak.
        #expect(latch.update(observed: .nominal, now: 5).pressure == .critical)
        #expect(latch.update(observed: .nominal, now: 24.9).pressure == .critical)
        let restored = latch.update(observed: .nominal, now: 25)
        #expect(restored.pressure == .nominal)
        #expect(!restored.needsRestoreRecheck)
    }

    @Test("Re-heating restarts the cool-down window")
    func reheatRestartsWindow() {
        var latch = ThermalHysteresis(restoreDelay: 20)
        _ = latch.update(observed: .serious, now: 0)
        _ = latch.update(observed: .nominal, now: 10)   // cool-down starts
        _ = latch.update(observed: .serious, now: 12)   // hot again
        #expect(latch.update(observed: .nominal, now: 30).pressure == .serious)
        #expect(latch.update(observed: .nominal, now: 50).pressure == .nominal)
    }

    @Test("A steady temperature clears the pending restore")
    func steadyClearsRestore() {
        var latch = ThermalHysteresis(restoreDelay: 20)
        _ = latch.update(observed: .serious, now: 0)
        #expect(latch.update(observed: .nominal, now: 1).needsRestoreRecheck)
        let steady = latch.update(observed: .serious, now: 2)
        #expect(steady.pressure == .serious)
        #expect(!steady.needsRestoreRecheck)
    }
}

/// The governor is the one place that reads real system state; these tests only exercise the
/// transitions it owns (foreground/background, memory pressure) so they stay deterministic.
@Suite("PerformanceGovernor", .serialized)
@MainActor
struct PerformanceGovernorTests {
    @Test("Foreground/background transitions shrink and restore the budget")
    func appActiveTransitions() {
        let governor = PerformanceGovernor(restoreDelay: 5)
        // `refresh()` publishes into the app-wide façade; other suites read it, so hand the
        // unconstrained placeholder back when this test finishes.
        defer { CassettePerformance.publish(.placeholder) }
        // Whatever the machine reports (thermal, Low Power, Reduce Motion), backgrounding must
        // remove the optional work and coming back must restore the *previous* policy — comparing
        // against the pre-background budget keeps this deterministic on a loaded CI box.
        let before = governor.budget
        governor.setAppActive(false)
        #expect(!governor.budget.isAppActive)
        #expect(!governor.budget.allowsDecorativeMotion)
        #expect(!governor.budget.allowsArtworkPrefetch)
        // The non-isolated façade must move in lockstep: that is what views and the audio render
        // thread actually read.
        #expect(CassettePerformance.budget == governor.budget)

        governor.setAppActive(true)
        #expect(governor.budget.isAppActive)
        #expect(governor.budget == before)
        governor.stop()
    }

    @Test("A memory warning defers heavy artwork work")
    func memoryPressureDefersHeavyWork() {
        let governor = PerformanceGovernor(restoreDelay: 5)
        defer { CassettePerformance.publish(.placeholder) }
        governor.handleMemoryPressure()
        #expect(governor.isMemoryPressured)
        #expect(!governor.budget.allowsHeavyColorAnalysis)
        #expect(!governor.budget.allowsBeatVisuals)
        governor.stop()
    }
}
