// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import Synchronization
import Observation
import SwiftUI

/// Live playback energy derived from AudioStreaming's mixer tap.
/// Drives full-player beat backgrounds and list now-playing equalizers.
///
/// Audio-thread samples are coalesced; `@Observable` properties update at most every
/// `CassettePerformance.beatPublishInterval` (4 Hz normally, 2.5 Hz on a constrained device) so
/// views are never invalidated on every mixer buffer.
@Observable
@MainActor
final class PlaybackBeatMeter {
    nonisolated static let filterName = "cassette.beatMeter"
    nonisolated static let bandCount = 4

    /// Shared instance; UI reads `level` / `beatPulse` / `bands` on the main actor.
    static let shared = PlaybackBeatMeter()

    /// Smoothed relative loudness suitable for UI (0 idle … 1 peak).
    private(set) var level: CGFloat = 0
    /// Short-window spike for punchier beat flashes.
    private(set) var beatPulse: CGFloat = 0
    /// Per-bar equalizer energies (0…1), driven by real audio — not a canned loop.
    private(set) var bands: [CGFloat] = Array(repeating: 0.12, count: bandCount)

    private var ema: Float = 0
    private var bandEMA: [Float] = Array(repeating: 0.08, count: bandCount)
    private var noiseFloor: Float = 0.02
    private var enabled = false
    /// Number of on-screen consumers (full-player wash, list equalizers, …).
    private var listenCount = 0

    nonisolated(unsafe) private static var lastMainHop: CFAbsoluteTime = 0
    /// Mirrors `listenCount > 0` for the audio thread so enqueue can no-op without a MainActor hop.
    nonisolated private static let uiListeningFlag = Atomic<Bool>(false)
    nonisolated private static let publishIntervalMilliseconds = Atomic<UInt64>(250)

    /// Called from the audio render thread — never blocks, rarely hops to MainActor.
    ///
    /// The band-energy computation is the expensive part, so it runs only when the publish
    /// interval has elapsed — not on every mixer buffer. Previously `bandEnergies` ran on every
    /// buffer (~hundreds of times/second) even though the UI only reads at 4 Hz, wasting CPU
    /// (and battery) while the full player is listening.
    nonisolated static func enqueue(buffer: AVAudioPCMBuffer) {
        // The performance budget keeps the UI from listening whenever live visuals are not allowed
        // (background, Low Power Mode, Reduce Motion, thermal pressure), so the audio thread only
        // pays one flag check here. See `PerformanceGovernor`.
        guard uiListeningFlag.load(ordering: .relaxed) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMainHop >= Double(publishIntervalMilliseconds.load(ordering: .relaxed)) / 1_000 else { return }
        lastMainHop = now
        let bands = bandEnergies(from: buffer)
        let snapshot = Array(bands.prefix(bandCount))
        Task { @MainActor in
            shared.apply(bands: snapshot)
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        refreshPerformanceBudget()
        if !on {
            level = 0
            beatPulse = 0
            ema = 0
            bandEMA = Array(repeating: 0.08, count: Self.bandCount)
            bands = Array(repeating: 0.12, count: Self.bandCount)
        }
    }

    /// Keep the mixer tap publishing while any UI consumer needs live energy.
    func retainUIListening() {
        listenCount += 1
        if listenCount == 1 {
            applyListeningState(true)
        }
    }

    func releaseUIListening() {
        listenCount = max(0, listenCount - 1)
        if listenCount == 0 {
            applyListeningState(false)
        }
    }

    private func applyListeningState(_ on: Bool) {
        refreshPerformanceBudget()
        if !on {
            level = 0
            beatPulse = 0
            bands = Array(repeating: 0.12, count: Self.bandCount)
        }
    }

    /// Re-applies the publish cadence after a budget change (thermal, Low Power Mode, background).
    /// Called by `PerformanceGovernor`; the audio thread reads `publishIntervalCached` per buffer,
    /// so this is how a hot device automatically drops from 4 Hz to 2.5 Hz visualization work.
    func refreshPerformanceBudget() {
        Self.publishIntervalMilliseconds.store(
            UInt64(CassettePerformance.beatPublishInterval * 1_000), ordering: .relaxed
        )
        Self.uiListeningFlag.store(
            enabled && listenCount > 0 && CassettePerformance.allowsBeatVisuals, ordering: .relaxed
        )
    }

    /// Publish coalesced band energies on the main actor.
    func apply(bands raw: [Float]) {
        guard enabled, listenCount > 0, CassettePerformance.allowsBeatVisuals else { return }

        var smoothed: [CGFloat] = []
        smoothed.reserveCapacity(Self.bandCount)
        var peak: Float = 0
        for i in 0..<Self.bandCount {
            let sample = i < raw.count ? max(0, raw[i]) : 0
            peak = max(peak, sample)
            noiseFloor = min(noiseFloor * 0.995 + sample * 0.005, 0.08)
            let normalized = max(0, (sample - noiseFloor) / max(0.001, 0.35 - noiseFloor))
            let clamped = min(1, normalized)
            if clamped > bandEMA[i] {
                bandEMA[i] = bandEMA[i] * 0.28 + clamped * 0.72
            } else {
                bandEMA[i] = bandEMA[i] * 0.78 + clamped * 0.22
            }
            smoothed.append(CGFloat(min(1, max(0.05, bandEMA[i]))))
        }

        let clampedPeak = min(1, max(0, (peak - noiseFloor) / max(0.001, 0.35 - noiseFloor)))
        if clampedPeak > ema {
            ema = ema * 0.35 + clampedPeak * 0.65
        } else {
            ema = ema * 0.82 + clampedPeak * 0.18
        }
        let spike = max(0, clampedPeak - ema)
        let newLevel = CGFloat(ema)
        let newPulse = CGFloat(min(1, spike * 2.4))

        if abs(newLevel - level) < 0.012,
           abs(newPulse - beatPulse) < 0.02,
           zip(smoothed, bands).allSatisfy({ abs($0 - $1) < 0.02 })
        {
            if beatPulse > 0.02 {
                beatPulse *= 0.85
            }
            return
        }
        level = newLevel
        beatPulse = newPulse
        bands = smoothed
    }

    /// Split the buffer into `bandCount` time slices and return per-slice RMS (real audio energy).
    nonisolated static func bandEnergies(from buffer: AVAudioPCMBuffer, bandCount: Int = bandCount) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, bandCount > 0 else {
            return Array(repeating: 0, count: bandCount)
        }

        func accumulate(into sums: inout [Float], counts: inout [Int], sample: Float, index: Int) {
            let band = min(bandCount - 1, index * bandCount / frameCount)
            sums[band] += sample * sample
            counts[band] += 1
        }

        var sums = Array(repeating: Float(0), count: bandCount)
        var counts = Array(repeating: 0, count: bandCount)
        let step = max(1, frameCount / (256 * bandCount))

        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                var i = 0
                while i < frameCount {
                    accumulate(into: &sums, counts: &counts, sample: data[i], index: i)
                    i += step
                }
            }
        } else if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let scale: Float = 1.0 / Float(Int16.max)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                var i = 0
                while i < frameCount {
                    accumulate(into: &sums, counts: &counts, sample: Float(data[i]) * scale, index: i)
                    i += step
                }
            }
        } else {
            return Array(repeating: 0, count: bandCount)
        }

        return (0..<bandCount).map { i in
            guard counts[i] > 0 else { return 0 }
            return sqrt(sums[i] / Float(counts[i]))
        }
    }
}
