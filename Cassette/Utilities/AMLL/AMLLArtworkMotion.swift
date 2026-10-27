// Swift adaptation of AMLL, AGPL-3.0-only; Copyright the AMLL contributors.
// Swift adaptation Copyright (C) 2026 Cassette contributors.
// Source: packages/core/src/bg-render/pixi-renderer.ts (onTick),
// upstream 5fee356362353dbb24ce9bea3a62536478040de7.
// See Resources/Licenses/AMLL-AGPL-3.0.txt.
import Foundation

/// Pixi's four rotating artwork sprites, sampled using seconds rather than ticker
/// callbacks. Frame rate and playback seeking cannot change their speed.
nonisolated enum AMLLArtworkMotion {
    static let defaultFlowSpeed = 1.0

    static func speed(_ value: Double) -> Double {
        value.isFinite ? min(4, max(0, value)) : defaultFlowSpeed
    }

    /// x/y: center in longest-edge units; z: square side; w: clockwise radians.
    /// Fixed starting rotations replace upstream randomness for stable redraws.
    static func layers(size: CGSize, elapsed: Double, flowSpeed: Double = defaultFlowSpeed) -> [SIMD4<Float>] {
        let width = size.width.isFinite ? max(1, Double(size.width)) : 1
        let height = size.height.isFinite ? max(1, Double(size.height)) : 1
        let longest = max(width, height)
        let time = (elapsed.isFinite ? max(0, elapsed) : 0) * 60 * speed(flowSpeed)
        let orbit = width / 4 * cos(time / 1000 * 0.75)
        let smallOrbit = width / 40 + cos(time * 0.006 * 0.75)
        let centers = [(width / 2, height / 2), (width / 2.5, height / 2.5),
                       (width / 2 + orbit, height / 2 + orbit),
                       (width / 2 + smallOrbit, height / 2 + smallOrbit)]
        let scales = [sqrt(2.0), 0.8, 0.5, 0.25]
        let rotations = [0.25 + time / 1000, 2.1 - time / 500,
                         4.2 + time / 1000, 5.4 - time / 750]
        return (0..<4).map { i in
            SIMD4(Float(centers[i].0 / longest), Float(centers[i].1 / longest),
                  Float(scales[i]), Float(rotations[i].truncatingRemainder(dividingBy: 2 * .pi)))
        }
    }
}
