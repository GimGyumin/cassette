import Foundation

/// Owns periodic persistence work independently of transport/engine state. The caller supplies
/// a weak, generation-checked snapshot; pausing and teardown synchronously cancel the timer.
nonisolated final class PlaybackCheckpointScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func start(interval: Duration = .seconds(30), checkpoint: @escaping @Sendable () async -> Void) {
        lock.withLock {
            task?.cancel()
            task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval, tolerance: .seconds(3)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await checkpoint()
                }
            }
        }
    }

    func stop() {
        lock.withLock { task?.cancel(); task = nil }
    }

    deinit { task?.cancel() }
}
