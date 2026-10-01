import Foundation

/// Estimates the current measured phase, never inventing a duration for unknown remaining work.
nonisolated struct PreparationETA {
    private var phase: LibraryPreparationPhase?
    private var startedAt: Date?
    private var baseline = 0

    mutating func estimate(_ progress: LibraryPreparationProgress, now: Date = Date()) -> Date? {
        if phase != progress.phase {
            phase = progress.phase
            startedAt = now
            baseline = progress.coversCompleted
        }
        guard progress.phase == .covers, let startedAt,
              progress.coversTotal > progress.coversCompleted else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        let completed = progress.coversCompleted - baseline
        guard elapsed >= 3, completed >= 2 else { return nil }
        let remaining = elapsed / Double(completed) * Double(progress.coversTotal - progress.coversCompleted)
        guard remaining.isFinite, remaining > 0 else { return nil }
        return now.addingTimeInterval(remaining)
    }
}
