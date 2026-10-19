import Foundation

/// Decoration owns a monotonic clock; it never reads playback position or PCM samples.
nonisolated struct ArtworkSceneClock: Sendable {
    private(set) var elapsed: TimeInterval = 0
    private(set) var isRunning = false
    private var lastTime: TimeInterval?

    mutating func setRunning(_ running: Bool, now: TimeInterval) {
        _ = sample(now: now)
        isRunning = running
    }

    mutating func sample(now: TimeInterval) -> TimeInterval {
        if isRunning, let lastTime { elapsed += max(0, now - lastTime) }
        lastTime = now
        return elapsed
    }
}

nonisolated enum ArtworkSceneMotion {
    static let framesPerSecond = 15
    static let crossfadeDuration: TimeInterval = 1.2
    static let maximumRenderDimension = 384

    static func renderSize(for size: CGSize) -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return (1, 1)
        }
        let scale = min(1, CGFloat(maximumRenderDimension) / max(size.width, size.height))
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    static func crossfadeProgress(elapsed: TimeInterval) -> Float {
        let progress = min(1, max(0, elapsed / crossfadeDuration))
        return Float(progress * progress * (3 - 2 * progress))
    }

    static func barHeight(index: Int, elapsed: TimeInterval, animated: Bool) -> CGFloat {
        let phases = [0.0, 1.7, 3.4, 5.1]
        let phase = phases[min(max(0, index), 3)]
        let energy = animated
            ? 0.18 + 0.82 * (sin(elapsed * (3.4 + Double(index) * 0.23) + phase) + 1) * 0.5
            : [0.22, 0.38, 0.28, 0.18][min(max(0, index), 3)]
        return 3 + 11 * CGFloat(energy)
    }
}
