// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Thermal pressure

/// Coarse thermal bucket derived from `ProcessInfo.ThermalState`.
///
/// `fair` is what a phone reports simply for being in use (or in the sun); it is not a problem
/// yet. `serious` is the system telling us it is throttling, so every optional cost goes away.
nonisolated enum ThermalPressure: Int, Comparable, Sendable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    /// Explicit because the compiler does not synthesise `Comparable` for an enum that also has a
    /// raw value. Ordering is the escalation order, which is what the raw values encode.
    static func < (lhs: ThermalPressure, rhs: ThermalPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    /// True once the device is actively shedding performance on our behalf.
    var requiresBackOff: Bool { self >= .serious }
}

// MARK: - Budget

/// Immutable snapshot of every battery-, thermal- and visibility-sensitive knob in the app.
///
/// One value decides how expensive Cassette is allowed to be, so the policy is reviewable in a
/// single place instead of being re-invented per view. Read it through ``CassettePerformance``
/// from non-isolated code (view bodies, the audio render thread) or through
/// `PerformanceGovernor.shared.budget` when a view should re-render on policy changes.
///
/// `make(thermalPressure:…)` is pure: no `ProcessInfo`, no globals. That is what makes the policy
/// unit-testable (`PerformanceBudgetTests`).
nonisolated struct PerformanceBudget: Equatable, Sendable {
    /// Effective thermal pressure (already latched by ``ThermalHysteresis``).
    let thermalPressure: ThermalPressure
    let isLowPowerMode: Bool
    /// False only while the app is fully backgrounded (scene phase == .background); a merely
    /// unfocused window keeps its animations.
    let isAppActive: Bool
    let reduceMotion: Bool
    /// True for a short window after a memory warning — avoid allocating big buffers.
    let isMemoryPressured: Bool
    /// Design-QA override (`cassette.forceLiquidGlass`); never overrides a hot or low-power device.
    let liquidGlassOverride: Bool

    /// Placeholder used before the governor publishes its first budget.
    static let placeholder = PerformanceBudget(
        thermalPressure: .nominal,
        isLowPowerMode: false,
        isAppActive: true,
        reduceMotion: false,
        isMemoryPressured: false,
        liquidGlassOverride: false
    )

    /// Pure policy. Every knob below is derived from these six inputs.
    static func make(
        thermalPressure: ThermalPressure,
        isLowPowerMode: Bool,
        isAppActive: Bool,
        reduceMotion: Bool,
        isMemoryPressured: Bool = false,
        liquidGlassOverride: Bool = false
    ) -> PerformanceBudget {
        PerformanceBudget(
            thermalPressure: thermalPressure,
            isLowPowerMode: isLowPowerMode,
            isAppActive: isAppActive,
            reduceMotion: reduceMotion,
            isMemoryPressured: isMemoryPressured,
            liquidGlassOverride: liquidGlassOverride
        )
    }

    /// Convenience for callers holding a raw `ProcessInfo.ThermalState`.
    static func make(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool,
        isAppActive: Bool,
        reduceMotion: Bool,
        isMemoryPressured: Bool = false,
        liquidGlassOverride: Bool = false
    ) -> PerformanceBudget {
        make(
            thermalPressure: ThermalPressure(thermalState),
            isLowPowerMode: isLowPowerMode,
            isAppActive: isAppActive,
            reduceMotion: reduceMotion,
            isMemoryPressured: isMemoryPressured,
            liquidGlassOverride: liquidGlassOverride
        )
    }

    /// The device cannot keep up with optional work (hot, throttled or saving power).
    private var isConstrained: Bool {
        isLowPowerMode || thermalPressure.requiresBackOff
    }

    // MARK: Motion

    /// Decorative motion (animated gradients, marquees, medallions) is the first cost to go:
    /// it is pure spend, and stopping it is invisible in terms of functionality.
    ///
    /// Backgrounded apps cost nothing, Reduce Motion users asked us to stop, Low Power Mode
    /// trades polish for runtime, and `serious`/`critical` means the device is already fighting.
    var allowsDecorativeMotion: Bool {
        isAppActive && !reduceMotion && !isConstrained
    }

    /// Live audio-reactive visuals add a mixer tap plus per-frame SwiftUI invalidation on top of
    /// decorative motion, so they share the gate (and stop entirely under memory pressure).
    var allowsBeatVisuals: Bool {
        allowsDecorativeMotion && !isMemoryPressured
    }

    // MARK: Chrome

    /// Liquid Glass is the normal foreground chrome, including in Low Power Mode. It falls back
    /// only while backgrounded or under serious thermal load, where compositing is unsafe.
    var liquidGlassAllowed: Bool {
        isAppActive && !thermalPressure.requiresBackOff
    }

    var prefersCheapChrome: Bool { !liquidGlassAllowed }

    // MARK: Background work

    /// k-means palette analysis of artwork — the most expensive non-audio CPU work in the app.
    /// Skipping it degrades to the memoized/cheap average colour, never to a broken screen.
    var allowsHeavyColorAnalysis: Bool {
        isAppActive && !isConstrained && !isMemoryPressured
    }

    /// Bulk (invisible) artwork prefetch keeps progressing while the device is warm, just slower;
    /// it is paced (instead of stopped) so long downloads still finish.
    var allowsArtworkPrefetch: Bool {
        isAppActive && thermalPressure < .critical && !isMemoryPressured
    }

    /// Bounded batch size for bulk cover downloads: full speed only on a cool, unconstrained,
    /// foreground device.
    var artworkPrefetchBatchSize: Int {
        guard allowsArtworkPrefetch, !isConstrained else { return 1 }
        return thermalPressure == .fair ? 2 : 3
    }

    /// Whether the engine may pre-buffer the *next* track while the current one plays (gapless).
    ///
    /// Deliberately not gated on Low Power Mode: gapless playback is a core listening behaviour,
    /// not decoration, and an armed bridge usually reads an already-cached file. It is gated on
    /// `critical` thermal pressure / memory pressure. Background audio still needs its next
    /// entry: locking the screen must not turn continuous playback into a cold-start per song.
    var allowsGaplessPrebuffer: Bool {
        thermalPressure < .critical && !isMemoryPressured
    }

    /// Sleep inserted between prefetch batches when the pass has to be paced (Low Power Mode,
    /// thermal pressure, background, memory warning).
    var artworkPrefetchPause: Duration? {
        allowsArtworkPrefetch && !isConstrained ? nil : .seconds(2)
    }

    // MARK: Rates

    /// Animated mesh hero (playlist / Wrapped headers) TimelineView interval.
    var meshFrameInterval: TimeInterval {
        isLowPowerMode ? 1.0 / 8.0 : 1.0 / 12.0
    }

    /// Beat-meter publish period. The audio thread computes band energies at most this often, and
    /// SwiftUI invalidates the full player / list equalizers at the same rate.
    var beatPublishInterval: TimeInterval {
        isConstrained ? 0.40 : 0.25
    }

    /// Lyrics tracking loop period. Karaoke words only read smoothly near 60 Hz; when the device
    /// is constrained half that rate is indistinguishable on a moving line of text.
    func lyricsTickIntervalNs(karaokePlayback: Bool) -> UInt64 {
        if isConstrained {
            return karaokePlayback ? 33_333_333 : 50_000_000
        }
        return karaokePlayback ? 16_666_666 : 33_333_333
    }

    /// One-line description for device-side verification (Console.app / Xcode Instruments).
    var summary: String {
        "thermal=\(thermalPressure) lowPower=\(isLowPowerMode) active=\(isAppActive) "
            + "reducedMotion=\(reduceMotion) memory=\(isMemoryPressured) "
            + "motion=\(allowsDecorativeMotion) beat=\(allowsBeatVisuals) glass=\(liquidGlassAllowed)"
    }
}

// MARK: - Hysteresis

/// Debounces thermal *recovery*.
///
/// Degrading is immediate — a hot device is telling us something and waiting would mean burning
/// battery and frame time before backing off. Restoring the expensive visuals, however, needs
/// `restoreDelay` seconds of a cooler device: otherwise a CPU hovering exactly on a thermal
/// boundary flaps the full player between "animated" and "flat" every few seconds, which costs
/// *more* work (rebuilding animations) and looks broken.
nonisolated struct ThermalHysteresis: Sendable {
    struct Outcome: Equatable, Sendable {
        /// Pressure the app should act on right now.
        let pressure: ThermalPressure
        /// True while waiting out `restoreDelay`; callers should re-check after that delay
        /// (thermal notifications only fire on change, so nobody else will).
        let needsRestoreRecheck: Bool
    }

    let restoreDelay: TimeInterval
    private(set) var applied: ThermalPressure
    private var cooledSince: TimeInterval?

    init(restoreDelay: TimeInterval, initial: ThermalPressure = .nominal) {
        self.restoreDelay = restoreDelay
        self.applied = initial
    }

    /// `now` is a monotonic timestamp (`ProcessInfo.processInfo.systemUptime`) — injectable so the
    /// behaviour is unit-testable without waiting in real time.
    mutating func update(observed: ThermalPressure, now: TimeInterval) -> Outcome {
        if observed > applied {
            applied = observed
            cooledSince = nil
            return Outcome(pressure: applied, needsRestoreRecheck: false)
        }
        guard observed < applied else {
            cooledSince = nil
            return Outcome(pressure: applied, needsRestoreRecheck: false)
        }
        // Cooler than what we are acting on: hold the degraded policy until it lasts.
        let since = cooledSince ?? now
        cooledSince = since
        guard now - since >= restoreDelay else {
            return Outcome(pressure: applied, needsRestoreRecheck: true)
        }
        applied = observed
        cooledSince = nil
        return Outcome(pressure: applied, needsRestoreRecheck: false)
    }
}

// MARK: - Governor

/// Single owner of the app's battery / thermal policy.
///
/// Everything that adapts to device conditions asks this object (directly or through the
/// ``CassettePerformance`` façade) instead of reading `ProcessInfo` ad hoc. It watches:
///
/// - thermal state (`ProcessInfo.thermalStateDidChangeNotification`)
/// - Low Power Mode (`.NSProcessInfoPowerStateDidChange`)
/// - memory warnings
/// - the Reduce Motion accessibility setting
/// - foreground / background (pushed by `CassetteApp`'s scene phase)
///
/// and turns all of it into one ``PerformanceBudget``, latched through ``ThermalHysteresis``.
@MainActor
@Observable
final class PerformanceGovernor {
    static let shared = PerformanceGovernor()

    /// How long the device must stay cool before expensive visuals come back.
    /// `nonisolated` because it is used as a default argument (evaluated outside the actor).
    nonisolated static let defaultRestoreDelay: TimeInterval = 20
    /// How long a memory warning keeps heavy artwork analysis off.
    nonisolated static let memoryPressureDuration: TimeInterval = 30

    /// Current policy. Views that read this during `body` re-render when it changes.
    private(set) var budget: PerformanceBudget
    /// What the system reports, before hysteresis.
    private(set) var reportedThermalPressure: ThermalPressure
    /// What the app acts on, after hysteresis.
    private(set) var appliedThermalPressure: ThermalPressure
    private(set) var isAppActive: Bool
    private(set) var isMemoryPressured = false

    private var hysteresis: ThermalHysteresis
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var restoreRecheck: Task<Void, Never>?
    private var memoryPressureDecay: Task<Void, Never>?
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    init(restoreDelay: TimeInterval = PerformanceGovernor.defaultRestoreDelay) {
        let observed = ThermalPressure(ProcessInfo.processInfo.thermalState)
        reportedThermalPressure = observed
        appliedThermalPressure = observed
        isAppActive = true
        hysteresis = ThermalHysteresis(restoreDelay: restoreDelay, initial: observed)
        budget = PerformanceBudget.make(
            thermalPressure: observed,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isAppActive: true,
            reduceMotion: Self.systemReduceMotion,
            liquidGlassOverride: CassettePerformance.forceLiquidGlass
        )
    }

    /// Starts observing system signals. Idempotent. Called from `CassetteApp.init()` — before the
    /// first view body — so no frame ever renders with the placeholder budget.
    func start() {
        registerObservers()
        refresh()
    }

    /// Stops observing (tests / previews).
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(macOS)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        #endif
        restoreRecheck?.cancel()
        restoreRecheck = nil
        memoryPressureDecay?.cancel()
        memoryPressureDecay = nil
    }

    /// Pushed by `CassetteApp` on scene-phase changes.
    func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        refresh()
    }

    /// A memory warning: stop allocating big artwork buffers for a while and let the caches be
    /// trimmed by their owners. The flag decays on its own so a single warning cannot permanently
    /// downgrade the UI.
    func handleMemoryPressure() {
        isMemoryPressured = true
        refresh()
        memoryPressureDecay?.cancel()
        memoryPressureDecay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.memoryPressureDuration))
            guard !Task.isCancelled, let self else { return }
            self.isMemoryPressured = false
            self.refresh()
        }
    }

    /// Re-reads the system state and republishes the budget. Cheap: pure computation over a few
    /// scalar reads. Returns the budget for the caller's convenience.
    @discardableResult
    func refresh() -> PerformanceBudget {
        let reported = ThermalPressure(ProcessInfo.processInfo.thermalState)
        reportedThermalPressure = reported
        let outcome = hysteresis.update(observed: reported, now: ProcessInfo.processInfo.systemUptime)
        appliedThermalPressure = outcome.pressure

        let next = PerformanceBudget.make(
            thermalPressure: outcome.pressure,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isAppActive: isAppActive,
            reduceMotion: Self.systemReduceMotion,
            isMemoryPressured: isMemoryPressured,
            liquidGlassOverride: CassettePerformance.forceLiquidGlass
        )
        // Always republish: the façade is read from the audio render thread and from view bodies
        // that are not observing this object.
        CassettePerformance.publish(next)
        if next != budget {
            budget = next
            PlaybackBeatMeter.shared.refreshPerformanceBudget()
            Logger.performance.notice("budget → \(next.summary, privacy: .public)")
        }
        scheduleRestoreRecheckIfNeeded(outcome.needsRestoreRecheck)
        return next
    }
}

// MARK: - Observation plumbing

private extension PerformanceGovernor {
    static var systemReduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }

    func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in PerformanceGovernor.shared.refresh() }
            }
        )
        observers.append(
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in PerformanceGovernor.shared.refresh() }
            }
        )
        #if canImport(UIKit)
        observers.append(
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in PerformanceGovernor.shared.handleMemoryPressure() }
            }
        )
        observers.append(
            center.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in PerformanceGovernor.shared.refresh() }
            }
        )
        #endif
        #if os(macOS)
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in PerformanceGovernor.shared.refresh() }
            }
        )
        // iOS delivers `didReceiveMemoryWarningNotification`; AppKit has no equivalent, so the
        // dispatch source is how the macOS build learns about pressure.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task { @MainActor in PerformanceGovernor.shared.handleMemoryPressure() }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    /// Thermal / power notifications only fire when the *reported* state changes, so a pending
    /// restore has to be re-checked by us once the cool-down window has elapsed.
    func scheduleRestoreRecheckIfNeeded(_ needed: Bool) {
        guard needed else {
            restoreRecheck?.cancel()
            restoreRecheck = nil
            return
        }
        guard restoreRecheck == nil else { return }
        let delay = hysteresis.restoreDelay
        restoreRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.restoreRecheck = nil
            self.refresh()
        }
    }
}
