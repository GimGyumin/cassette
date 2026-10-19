// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Synchronization

/// Lock-free read façade for the app-wide ``PerformanceBudget``.
///
/// The policy itself lives in ``PerformanceGovernor`` (MainActor); this enum only republishes the
/// latest snapshot into a static, so non-isolated readers — view bodies and the audio render
/// thread — can ask "am I allowed to be expensive?" without a lock, an actor hop, or a
/// `ProcessInfo` call on every frame / audio buffer.
///
/// Prefer reading the governor's `budget` directly inside SwiftUI `body` when a view must
/// *re-render* on a policy change (Observation tracks that read); use these statics from services,
/// view models and the audio thread.
nonisolated enum CassettePerformance {
    private static let published = PerformanceBudgetStore()

    static var budget: PerformanceBudget { published.load() }

    static func publish(_ budget: PerformanceBudget) {
        published.store(budget)
    }

    // MARK: - Chrome

    /// Skip `glassEffect` only when the runtime budget detects a constrained device.
    static var preferCheapChrome: Bool { budget.prefersCheapChrome }

    // MARK: - Motion

    /// Continuous mesh / TimelineView motion — off in the background, under Low Power Mode,
    /// Reduce Motion, and once the device reports `serious`/`critical` thermal pressure.
    static var allowDecorativeMotion: Bool { budget.allowsDecorativeMotion }

    /// Audio-reactive visuals (full-player wash, list equalizers).
    static var allowsBeatVisuals: Bool { budget.allowsBeatVisuals }

    // MARK: - Artwork work

    /// k-means artwork palette analysis. False → callers fall back to the memoized / cheap average
    /// colour instead of dropping the artwork itself.
    static var allowsHeavyColorAnalysis: Bool { budget.allowsHeavyColorAnalysis }

    /// Bulk (invisible) cover prefetch; paced rather than stopped while the device is warm.
    static var allowsArtworkPrefetch: Bool { budget.allowsArtworkPrefetch }
    static var artworkPrefetchBatchSize: Int { budget.artworkPrefetchBatchSize }
    static var artworkPrefetchPause: Duration? { budget.artworkPrefetchPause }

    /// Whether the audio engine may pre-buffer the next track (gapless playback).
    static var allowsGaplessPrebuffer: Bool { budget.allowsGaplessPrebuffer }

    // MARK: - Rates

    /// Animated gradient hero TimelineView interval.
    static var meshHeroFrameInterval: TimeInterval { budget.meshFrameInterval }

    /// Beat-meter publish period in seconds — read by the audio render thread.
    static var beatPublishInterval: TimeInterval { budget.beatPublishInterval }

    /// Lyrics tracking loop period, coarser on a constrained device.
    static func lyricsTickIntervalNs(karaokePlayback: Bool) -> UInt64 {
        budget.lyricsTickIntervalNs(karaokePlayback: karaokePlayback)
    }

    // MARK: - QA override

    /// Design-QA escape hatch (UserDefaults key `cassette.forceLiquidGlass`). Only
    /// ``PerformanceGovernor`` reads it: the budget still refuses Liquid Glass while the device is
    /// hot, in Low Power Mode, or backgrounded.
    static var forceLiquidGlass: Bool {
        UserDefaults.standard.bool(forKey: "cassette.forceLiquidGlass")
    }
}

/// All six policy inputs fit in one atomic byte. Readers get one complete snapshot,
/// without a lock or a data race on a multi-field Swift value.
nonisolated final class PerformanceBudgetStore: Sendable {
    private let bits: Atomic<UInt8>

    init(_ budget: PerformanceBudget = .placeholder) {
        bits = Atomic(Self.encode(budget))
    }

    func store(_ budget: PerformanceBudget) {
        bits.store(Self.encode(budget), ordering: .relaxed)
    }

    func load() -> PerformanceBudget {
        let value = bits.load(ordering: .relaxed)
        return .make(
            thermalPressure: ThermalPressure(rawValue: Int(value & 3)) ?? .nominal,
            isLowPowerMode: value & 4 != 0,
            isAppActive: value & 8 != 0,
            reduceMotion: value & 16 != 0,
            isMemoryPressured: value & 32 != 0,
            liquidGlassOverride: value & 64 != 0
        )
    }

    private static func encode(_ budget: PerformanceBudget) -> UInt8 {
        UInt8(budget.thermalPressure.rawValue)
            | (budget.isLowPowerMode ? 4 : 0)
            | (budget.isAppActive ? 8 : 0)
            | (budget.reduceMotion ? 16 : 0)
            | (budget.isMemoryPressured ? 32 : 0)
            | (budget.liquidGlassOverride ? 64 : 0)
    }
}
