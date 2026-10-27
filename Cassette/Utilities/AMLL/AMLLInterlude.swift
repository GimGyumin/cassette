// Swift adaptation of AMLL, AGPL-3.0-only; Copyright the AMLL contributors.
// Swift adaptation Copyright (C) 2026 Cassette contributors.
// Source: packages/core/src/lyric-player/base/interlude-dots.ts at
// 5fee356362353dbb24ce9bea3a62536478040de7. See Resources/Licenses/AMLL-AGPL-3.0.txt.
// Native sampling uses the audio clock directly; no RAF clock or DOM lifecycle is needed.

import Foundation

nonisolated struct AMLLInterlude: Equatable, Sendable {
    var dots: [Double] = [0, 0, 0]
    var scale = 1.0
    var opacity = 0.0

    static func sample(elapsedMs: Double, durationMs: Double, intro: Bool, motion: Bool = true) -> Self {
        let hold = intro ? 0.0 : 500.0
        let body = durationMs - hold - 1000
        guard body >= 910, elapsedMs >= hold, elapsedMs < durationMs,
              elapsedMs.isFinite, durationMs.isFinite else { return Self() }
        let internalTime = elapsedMs - hold
        let exitTime = internalTime - body
        let fallback = body < 3000
        let segment = ((body + 750) / 3).rounded()
        let thirdDuration = body - segment * 2
        let thirdTarget = fallback ? 1 : thirdDuration / segment
        var value = Self()
        value.opacity = AMLLCurve.bezier(internalTime / 180, 0.59, 0.02, 0.07, 1)
        var fractions: [Double]
        if exitTime >= 0 {
            value.opacity *= 1 - AMLLCurve.bezier((exitTime - 750) / 250, 0.43, 0.08, 0.83, 0.31)
            if exitTime < 750 {
                value.scale = 1 + AMLLCurve.bezier(exitTime / 750, 0.14, 0.06, 0.25, 1) * 0.25
            } else {
                value.scale = 1.25 - AMLLCurve.bezier((exitTime - 750) / 250, 0.29, 0.03, 1, 0.38) * 0.85
            }
            fractions = [1, 1, thirdTarget + (1 - thirdTarget) * AMLLCurve.clamp(exitTime / 750)]
        } else if fallback {
            fractions = [1, 1, 1]
        } else {
            let period = body / max(1, floor(body / 4000))
            let t = internalTime.truncatingRemainder(dividingBy: period) / period
            let angle = 4 * Double.pi * t, s = sin(angle), c = cos(angle)
            let progress = t - 0.084 * s + 0.008 * (1 - c) + 0.0046 * s * (c - s)
            value.scale = progress <= 0.5 ? 1 + progress * 0.5 : 1.25 - (progress - 0.5) * 0.5
            fractions = (0..<3).map { i in
                let duration = i == 2 ? thirdDuration : segment
                let target = i == 2 ? thirdTarget : 1
                return AMLLCurve.bezier((internalTime - Double(i) * segment) / max(1, duration),
                    0.56, 0.01, 0.45, 1) * target
            }
        }
        value.dots = fractions.enumerated().map { i, fraction in
            let enter = AMLLCurve.clamp((internalTime - Double(i) * 80) / 750)
            return (0.2 + 0.7 * AMLLCurve.clamp(fraction)) * enter * enter
        }
        if !motion { value.scale = 1 }
        return value
    }
}
