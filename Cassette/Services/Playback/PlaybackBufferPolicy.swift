import Foundation

/// Forward-buffer targets after startup, not startup thresholds. AVFoundation retains control
/// of when playback is sustainable; local files need no network cushion.
nonisolated enum PlaybackBufferPolicy {
    static func forwardBuffer(isLocal: Bool, isLimited: Bool) -> TimeInterval {
        isLocal ? 0 : (isLimited ? 20 : 10)
    }
}

/// A persistent wait emits only one KVO event. Sample the media clock using monotonic time
/// so both initial buffering and a later underrun have the same bounded recovery policy.
nonisolated struct PlaybackStallMonitor {
    private var lastMediaTime: Double?
    private var stalledSince: TimeInterval?

    mutating func observe(
        mediaTime: Double, now: TimeInterval, cannotPlay: Bool, isSeeking: Bool
    ) -> Bool {
        defer { lastMediaTime = mediaTime.isFinite ? mediaTime : nil }
        let advancing = mediaTime.isFinite && lastMediaTime.map { mediaTime - $0 >= 0.05 } == true
        let jumpedBack = mediaTime.isFinite && lastMediaTime.map { mediaTime < $0 - 0.05 } == true
        guard cannotPlay, !isSeeking, !advancing, !jumpedBack else {
            stalledSince = nil
            return false
        }
        if stalledSince == nil { stalledSince = now }
        return now - (stalledSince ?? now) >= 12
    }
}
