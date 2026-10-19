import Foundation

/// Refill only when a transfer finishes. Lowering the budget drains excess work without
/// polling or cancelling completed bytes; cancellation prevents every subsequent submission.
nonisolated enum DownloadBatchRunner {
    static func run<Item: Sendable>(
        _ items: [Item],
        maximumConcurrent: @escaping @Sendable () -> Int = { CassettePerformance.budget.maximumConcurrentDownloads },
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        operation: @escaping @Sendable (Item) async -> Bool
    ) async throws -> Int {
        try Task.checkCancellation()
        guard await shouldContinue() else { throw CancellationError() }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            var iterator = items.makeIterator()
            var active = 0
            var succeeded = 0
            func capacity() -> Int { max(1, min(8, maximumConcurrent())) }
            for _ in 0..<capacity() {
                guard let item = iterator.next() else { break }
                active += 1
                group.addTask {
                    guard !Task.isCancelled, await shouldContinue() else { throw CancellationError() }
                    return await operation(item)
                }
            }
            while let success = try await group.next() {
                active -= 1
                if success { succeeded += 1 }
                try Task.checkCancellation()
                guard await shouldContinue() else { group.cancelAll(); throw CancellationError() }
                while active < capacity(), let item = iterator.next() {
                    active += 1
                    group.addTask {
                        guard !Task.isCancelled, await shouldContinue() else { throw CancellationError() }
                        return await operation(item)
                    }
                }
            }
            return succeeded
        }
    }
}
