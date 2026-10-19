import CryptoKit
import Foundation

/// Equal only for the same account revision and byte-producing request. Codec, bitrate,
/// container, channel, offset and Range parameters remain part of the key.
nonisolated struct MediaTransferKey: Hashable, Codable, Sendable {
    let accountID: UUID
    let revision: UInt64
    let songID: String
    private let requestDigest: String

    init(accountID: UUID, revision: UInt64, songID: String, request: URLRequest) {
        self.accountID = accountID; self.revision = revision; self.songID = songID
        var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let authentication: Set<String> = ["u", "p", "t", "s", "v", "c", "api_key", "access_token"]
        let queryItems = components?.queryItems?.filter { !authentication.contains($0.name.lowercased()) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components?.queryItems = queryItems
        let headers = (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }.sorted { $0.0 < $1.0 }
        var bytes = Data(([request.httpMethod ?? "GET", components?.string ?? ""] + headers.map { "\($0.0):\($0.1)" }).joined(separator: "\n").utf8)
        if let body = request.httpBody { bytes.append(body) }
        requestDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct CachedMediaTransfer: Sendable {
    let url: URL
    let response: URLResponse
    private let fingerprint: Fingerprint
    private struct Fingerprint: Sendable, Equatable {
        let inode: UInt64; let size: UInt64; let modified: Date
    }
    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast)
    }
    init(url: URL, response: URLResponse) throws {
        self.url = url; self.response = response; fingerprint = try Self.fingerprint(url)
    }

    /// A cache eviction/replacement is a miss. Never promote a different format that later
    /// occupied the same cache filename, and never move the cache's only copy.
    func copyForInstallation() async -> URL? {
        await Task.detached(priority: .utility) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-transfer-\(UUID())")
            do {
                guard try Self.fingerprint(url) == fingerprint else { return nil }
                try LocalAudioFileStore.install(url, at: copy, sharesImmutableSource: true)
                guard try Self.fingerprint(url) == fingerprint else { throw CancellationError() }
                return copy
            } catch { try? FileManager.default.removeItem(at: copy); return nil }
        }.value
    }
}

/// Coordinates whole-file transfers without interfering with the engines' Range requests.
/// Permanent downloads retain their background URLSession/journal. They supersede a matching
/// cache transfer, waiting for its cancellation, or reuse its completed validated file.
actor MediaTransferCoordinator {
    private enum Role { case cache, permanent }
    private struct Flight {
        let id: UUID
        let role: Role
        let task: Task<CachedMediaTransfer?, Error>
        var consumers: Set<UUID>
    }
    private var flights: [MediaTransferKey: Flight] = [:]
    private var completed = CostBoundedCache<MediaTransferKey, CachedMediaTransfer>(countLimit: 32, costLimit: 32)

    /// Internal diagnostics for deterministic cancellation/draining regression tests.
    func consumerCount(for key: MediaTransferKey) -> Int { flights[key]?.consumers.count ?? 0 }

    func cache(_ key: MediaTransferKey, operation: @escaping @Sendable () async throws -> CachedMediaTransfer) async throws {
        guard flights[key] == nil, !Task.isCancelled else { return }
        let id = UUID(), consumer = UUID()
        let task = Task<CachedMediaTransfer?, Error> { try await operation() }
        flights[key] = Flight(id: id, role: .cache, task: task, consumers: [consumer])
        _ = try await wait(key, id: id, consumer: consumer, task: task)
    }

    func permanent(_ key: MediaTransferKey, operation: @escaping @Sendable (CachedMediaTransfer?) async throws -> Void) async throws {
        try Task.checkCancellation()
        let consumer = UUID()
        if var flight = flights[key], flight.role == .permanent {
            flight.consumers.insert(consumer); flights[key] = flight
            _ = try await wait(key, id: flight.id, consumer: consumer, task: flight.task)
            return
        }
        let prior = flights[key]?.task
        prior?.cancel()
        let cached = completed.value(forKey: key)
        let id = UUID()
        let task = Task<CachedMediaTransfer?, Error> {
            let finished = try? await prior?.value
            try Task.checkCancellation()
            try await operation(finished ?? cached)
            return nil
        }
        flights[key] = Flight(id: id, role: .permanent, task: task, consumers: [consumer])
        _ = try await wait(key, id: id, consumer: consumer, task: task)
    }

    private func wait(_ key: MediaTransferKey, id: UUID, consumer: UUID,
                      task: Task<CachedMediaTransfer?, Error>) async throws -> CachedMediaTransfer? {
        defer { release(key, id: id, consumer: consumer, finished: true) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            if let result { completed.insert(result, forKey: key, cost: 1) }
            return result
        } onCancel: {
            Task { await self.release(key, id: id, consumer: consumer) }
        }
    }

    private func release(_ key: MediaTransferKey, id: UUID, consumer: UUID, finished: Bool = false) {
        guard var flight = flights[key], flight.id == id else { return }
        flight.consumers.remove(consumer)
        if flight.consumers.isEmpty {
            flight.task.cancel()
            flights[key] = finished ? nil : flight
        } else { flights[key] = flight }
    }
}
