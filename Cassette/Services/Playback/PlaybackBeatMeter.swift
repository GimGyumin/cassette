// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import Synchronization
import Observation
import SwiftUI

/// Live playback energy from decoded AudioStreaming/native-player PCM.
/// Only visible list indicators listen; the artwork renderer never observes this meter.
///
/// Audio-thread samples are coalesced; `@Observable` properties update at most every
/// `CassettePerformance.beatPublishInterval` (20 Hz normally, 2.5 Hz on a constrained device) so
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
    /// Number of visible list equalizers. The player wash never subscribes.
    private var listenCount = 0
    @ObservationIgnored private var publicationTask: Task<Void, Never>?
    private var consumedRevision: UInt64 = 0
    nonisolated private static let mailbox = PlaybackMeterMailbox()

    nonisolated private static let lastPublishTime = Atomic<UInt64>(0)
    nonisolated private static let publicationGeneration = Atomic<UInt64>(0)
    /// Mirrors `listenCount > 0` for the audio thread so enqueue can no-op without a MainActor hop.
    nonisolated private static let uiListeningFlag = Atomic<Bool>(false)
    nonisolated private static let publishIntervalMilliseconds = Atomic<UInt64>(50)

    /// Gate work before inspecting any samples. Atomic reservation also coalesces concurrent
    /// graph/native callbacks without a render-thread lock or unsafe shared timestamp.
    nonisolated private static func reservePublication() -> UInt64? {
        guard uiListeningFlag.load(ordering: .relaxed) else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastPublishTime.load(ordering: .relaxed)
        guard now >= last,
              now - last >= publishIntervalMilliseconds.load(ordering: .relaxed) * 1_000_000,
              lastPublishTime.compareExchange(expected: last, desired: now, ordering: .relaxed).exchanged else { return nil }
        return publicationGeneration.load(ordering: .relaxed)
    }

    nonisolated static func enqueue(buffer: AVAudioPCMBuffer) {
        guard let generation = reservePublication() else { return }
        mailbox.publish(fourBandEnergies(bufferList: buffer.audioBufferList,
            format: buffer.format.streamDescription.pointee, frameCount: Int(buffer.frameLength)), generation: generation)
    }

    /// Borrow native tap storage only inside its process callback; never enqueue pointers.
    nonisolated static func enqueue(bufferList: UnsafePointer<AudioBufferList>,
                                   format: AudioStreamBasicDescription, frameCount: Int) {
        guard let generation = reservePublication() else { return }
        mailbox.publish(fourBandEnergies(bufferList: bufferList, format: format, frameCount: frameCount), generation: generation)
    }

    private func consumeLatestSample() {
        guard let sample = Self.mailbox.latest(), sample.revision != consumedRevision,
              sample.generation == Self.publicationGeneration.load(ordering: .relaxed) else { return }
        consumedRevision = sample.revision
        // Arrays and Observation updates happen only on MainActor, never in a render callback.
        apply(bands: [sample.bands.x, sample.bands.y, sample.bands.z, sample.bands.w])
    }

    func setEnabled(_ on: Bool) {
        if enabled != on { Self.publicationGeneration.wrappingAdd(1, ordering: .relaxed) }
        enabled = on
        refreshPerformanceBudget()
        if !on {
            Self.publicationGeneration.wrappingAdd(1, ordering: .relaxed)
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
            Self.publicationGeneration.wrappingAdd(1, ordering: .relaxed)
            level = 0
            beatPulse = 0
            bands = Array(repeating: 0.12, count: Self.bandCount)
        }
    }

    /// Re-applies cadence and visibility policy after thermal/power/foreground changes.
    func refreshPerformanceBudget() {
        Self.publishIntervalMilliseconds.store(
            UInt64(CassettePerformance.beatPublishInterval * 1_000), ordering: .relaxed
        )
        let active = enabled && listenCount > 0 && CassettePerformance.allowsBeatVisuals
        Self.uiListeningFlag.store(active, ordering: .relaxed)
        if !active {
            publicationTask?.cancel()
            publicationTask = nil
        } else if publicationTask == nil {
            publicationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(CassettePerformance.beatPublishInterval)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    self?.consumeLatestSample()
                }
            }
        }
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

    /// Render-thread path: four fixed SIMD lanes, no arrays, tasks, or locks.
    nonisolated static func fourBandEnergies(bufferList: UnsafePointer<AudioBufferList>,
                                             format: AudioStreamBasicDescription, frameCount: Int) -> SIMD4<Float> {
        guard frameCount > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return .zero }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        guard (floating && (bytes == 4 || bytes == 8)) || (signed && (bytes == 2 || bytes == 4)) else { return .zero }
        var sums = SIMD4<Float>.zero
        var counts = SIMD4<Float>.zero
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let step = max(1, frameCount / 1024)
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = min(frameCount, Int(buffer.mDataByteSize) / (bytes * channels))
            for frame in stride(from: 0, to: frames, by: step) {
                let band = min(3, frame * 4 / frameCount)
                for channel in 0..<min(8, channels) {
                    let index = frame * channels + channel
                    let value: Float
                    if floating {
                        value = bytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                            : Float(data.assumingMemoryBound(to: Double.self)[index])
                    } else {
                        value = bytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                    }
                    guard value.isFinite else { continue }
                    sums[band] += value * value
                    counts[band] += 1
                }
            }
        }
        for band in 0..<4 { sums[band] = counts[band] > 0 ? (sums[band] / counts[band]).squareRoot() : 0 }
        return sums
    }

    /// Split the buffer into `bandCount` time slices and return per-slice RMS (real audio energy).
    nonisolated static func bandEnergies(from buffer: AVAudioPCMBuffer, bandCount: Int = bandCount) -> [Float] {
        bandEnergies(bufferList: buffer.audioBufferList, format: buffer.format.streamDescription.pointee,
                     frameCount: Int(buffer.frameLength), bandCount: bandCount)
    }

    /// Handles the tap's actual output format without forcing sample rate, channel layout or
    /// downmixing. Work is bounded to about 1024 samples per channel, at the UI publish cadence.
    nonisolated static func bandEnergies(bufferList: UnsafePointer<AudioBufferList>,
                                       format: AudioStreamBasicDescription, frameCount: Int,
                                       bandCount: Int = bandCount) -> [Float] {
        guard frameCount > 0, bandCount > 0, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            return Array(repeating: 0, count: max(0, bandCount))
        }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        guard (floating && [4, 8].contains(bytes)) || (signed && [2, 4].contains(bytes)) else {
            return Array(repeating: 0, count: bandCount)
        }
        var sums = Array(repeating: Float(0), count: bandCount)
        var counts = Array(repeating: 0, count: bandCount)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let step = max(1, frameCount / (256 * bandCount))
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = min(frameCount, Int(buffer.mDataByteSize) / (bytes * channels))
            for frame in stride(from: 0, to: frames, by: step) {
                let band = min(bandCount - 1, frame * bandCount / frameCount)
                for channel in 0..<min(8, channels) {
                    let index = frame * channels + channel
                    let value: Float
                    if floating {
                        value = bytes == 4 ? data.assumingMemoryBound(to: Float.self)[index]
                            : Float(data.assumingMemoryBound(to: Double.self)[index])
                    } else {
                        value = bytes == 2 ? Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                            : Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                    }
                    guard value.isFinite else { continue }
                    sums[band] += value * value
                    counts[band] += 1
                }
            }
        }
        return (0..<bandCount).map { counts[$0] > 0 ? sqrt(sums[$0] / Float(counts[$0])) : 0 }
    }
}
