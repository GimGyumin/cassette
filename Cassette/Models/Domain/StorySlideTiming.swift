import Foundation

/// Monotonic, event-driven timing. Paused/background time never consumes a slide.
nonisolated struct StorySlideTiming: Hashable {
    let duration: TimeInterval
    private(set) var elapsed: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    var progress: Double { min(1, elapsed / duration) }
    var remaining: TimeInterval { max(0, duration - elapsed) }

    mutating func resume(at now: TimeInterval) {
        guard startedAt == nil, remaining > 0 else { return }
        startedAt = now
    }

    mutating func pause(at now: TimeInterval) {
        guard let start = startedAt else { return }
        elapsed = min(duration, elapsed + max(0, now - start))
        startedAt = nil
    }
}
