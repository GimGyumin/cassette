// Swift adaptation of Apple Music Like Lyrics (AMLL), AGPL-3.0-only.
// Copyright the AMLL contributors. Swift adaptation Copyright (C) 2026 Cassette contributors.
// Upstream 5fee356362353dbb24ce9bea3a62536478040de7, packages/core/src:
// lyric-player/base/{spring,seek-detector}.ts, dom/animation/{float,emphasize}/index.ts,
// dom/animation/mask/animator-calc.ts. See Resources/Licenses/AMLL-AGPL-3.0.txt.

import Foundation

nonisolated enum AMLLCurve {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x.isFinite ? x : 0)) }

    /// CSS cubic-bezier evaluated in x, rather than treating its parameter as time.
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = clamp(x)
        if x == 0 || x == 1 { return x }
        func value(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            if value(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return value((lo + hi) / 2, y1, y2)
    }

    // The source emits 32 WAAPI keyframes. Sample those frames once, then interpolate.
    static let emphasisFrames: [Double] = (0...32).map { i in
        let t = Double(i) / 32
        return t < 0.5 ? bezier(t * 2, 0.2, 0.4, 0.58, 1)
            : 1 - bezier((t - 0.5) * 2, 0.3, 0, 0.58, 1)
    }
    static let floatFrames: [Double] = (0...32).map { sin(Double($0) / 32 * .pi) }
    static let easeOutFrames: [Double] = (0...64).map { bezier(Double($0) / 64, 0, 0, 0.58, 1) }
    static func sample(_ frames: [Double], _ progress: Double) -> Double {
        let position = clamp(progress) * Double(frames.count - 1)
        let lower = Int(position), upper = min(frames.count - 1, lower + 1)
        return frames[lower] + (frames[upper] - frames[lower]) * (position - Double(lower))
    }
}

nonisolated struct AMLLSpringPolicy: Equatable, Sendable {
    let stiffness: Double
    let damping: Double
    static func position(seeking: Bool, interlude: Bool = false, intervalMs: Double?, endOfSong: Bool = false) -> Self {
        if seeking || interlude { return Self(stiffness: 90, damping: 15) }
        if endOfSong { return Self(stiffness: 140, damping: 22) }
        guard let intervalMs, intervalMs.isFinite else { return Self(stiffness: 90, damping: 15) }
        let ratio = pow(1 - (min(800, max(100, intervalMs)) - 100) / 700, 0.2)
        let stiffness = 170 + ratio * 50
        return Self(stiffness: stiffness, damping: sqrt(stiffness) * 2.2)
    }
    static func stagger(visibleOrdinal: Int, focalOrdinal: Int, seeking: Bool) -> Double {
        guard !seeking, visibleOrdinal > 0 else { return 0 }
        var delay = 0.0, step = 0.05
        for i in 0..<min(visibleOrdinal, 12) {
            delay += step
            if i >= focalOrdinal { step /= 1.05 }
        }
        return delay
    }
}

nonisolated struct AMLLSeekDetector: Sendable {
    private var previous: (media: Double, wall: Double)?
    mutating func reset() { previous = nil }
    mutating func detect(mediaMs: Double, wallMs: Double, playing: Bool) -> Bool {
        guard mediaMs.isFinite, wallMs.isFinite else { reset(); return false }
        defer { previous = (mediaMs, wallMs) }
        guard let previous else { return false }
        if mediaMs < previous.media { return true }
        let elapsed = min(800, max(0, wallMs - previous.wall))
        let expected = playing ? elapsed : 0
        let tolerance = playing ? max(150, elapsed * 0.5) : 150
        return mediaMs - previous.media - expected > tolerance
    }
}

nonisolated struct AMLLGlyphStyle: Equatable, Sendable {
    var lift = 0.0
    var shiftX = 0.0
    var scale = 1.0
    var glow = 0.0
    var glowRadius = 0.0

    /// Sampling time for a native row that has left the animated window. Covers
    /// the last-word multiplier, per-character delay and extended float duration.
    static func settledTime(startMs: Double, endMs: Double) -> Double {
        endMs + max(1000, endMs - startMs) * 2 + 1000
    }

    static func shouldEmphasize(text: String, durationMs: Double) -> Bool {
        guard durationMs >= 1000 else { return false }
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return isCJK(text) || (count > 1 && count <= 7)
    }

    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    static func sample(timeMs: Double, startMs: Double, endMs: Double, fontSize: Double,
                       character: Int, count: Int, emphasized: Bool, lastWord: Bool,
                       background: Bool, motion: Bool, emphasisStartMs: Double? = nil, emphasisEndMs: Double? = nil) -> Self {
        guard motion, timeMs.isFinite, startMs.isFinite, endMs.isFinite else { return Self() }
        var result = Self()
        let duration = max(1000, endMs - startMs)
        let up = fontSize * (background ? 0.10 : 0.05)
        // The source's ordinary word float is fill:both and keeps its final lift.
        result.lift = up * AMLLCurve.sample(AMLLCurve.easeOutFrames, (timeMs - startMs) / duration)
        guard emphasized else { return result }
        let emphasisStart = emphasisStartMs ?? startMs
        let emphasisDuration = max(1000, (emphasisEndMs ?? endMs) - emphasisStart)
        var amount = emphasisDuration / 2000, blur = emphasisDuration / 3000
        amount = (amount > 1 ? sqrt(amount) : pow(amount, 3)) * 0.6
        blur = (blur > 1 ? sqrt(blur) : pow(blur, 3)) * 0.5
        let du = emphasisDuration * (lastWord ? 1.2 : 1)
        amount = min(1.2, amount * (lastWord ? 1.6 : 1))
        blur = min(0.8, blur * (lastWord ? 1.5 : 1))
        let delay = du / 2.5 / Double(max(1, count)) * Double(character)
        let elapsed = timeMs - emphasisStart - delay
        let emphasis = AMLLCurve.sample(AMLLCurve.emphasisFrames, elapsed / du)
        result.scale = 1 + emphasis * 0.1 * amount
        result.shiftX = -emphasis * 0.03 * amount * (Double(count) / 2 - Double(character)) * fontSize
        result.lift += emphasis * 0.025 * amount * fontSize
        result.lift += up * AMLLCurve.sample(AMLLCurve.floatFrames, (elapsed + 400) / (du * 1.4))
        result.glow = emphasis * blur
        result.glowRadius = min(0.3, blur * 0.3) * fontSize
        return result
    }
}

nonisolated enum AMLLWordMask {
    /// Native equivalent of CalcMaskAnimator's CSS mask center. Whitespace and
    /// wrapped shaping runs participate in width, but never acquire new timestamps.
    static func edge(timeMs: Double, startMs: Double, endMs: Double, width: Double, fadeWidth: Double) -> Double {
        let duration = max(1, abs(endMs - startMs))
        return min(width + fadeWidth, max(-fadeWidth, (timeMs - startMs) * width / duration))
    }
}
