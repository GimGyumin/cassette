import Foundation

/// Serializes pin publication and automatic cleanup in the shared audio directory.
nonisolated final class ManagedAudioStore: @unchecked Sendable {
    static let shared = ManagedAudioStore()
    private let lock = NSRecursiveLock()
    private var leases: [String: Int] = [:]
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    func acquire(_ url: URL) { withLock { leases[url.standardizedFileURL.path, default: 0] += 1 } }
    func release(_ url: URL) {
        withLock {
            let key = url.standardizedFileURL.path
            let count = (leases[key] ?? 1) - 1
            leases[key] = count > 0 ? count : nil
        }
    }
    func isLeased(_ url: URL) -> Bool { withLock { leases[url.standardizedFileURL.path] != nil } }
}
