import Foundation
import Testing
@testable import Cassette

struct MediaTransferCoordinationTests {
    private func key(_ query: String = "format=raw", account: UUID, revision: UInt64 = 1, range: String? = nil) -> MediaTransferKey {
        var request = URLRequest(url: URL(string: "https://example.invalid/rest/stream?id=song&\(query)")!)
        request.setValue(range, forHTTPHeaderField: "Range")
        return MediaTransferKey(accountID: account, revision: revision, songID: "song", request: request)
    }

    @Test func transferIdentityPreservesFormatRangeAndAccount() {
        let account = UUID(), original = key(account: account)
        #expect(original == key("t=one&s=salt&format=raw", account: account))
        #expect(original != key("format=aac&maxBitRate=256", account: account))
        #expect(original != key(account: account, range: "bytes=10-"))
        #expect(original != key(account: account, revision: 2))
        #expect(original != key(account: UUID()))
    }

    @Test func completedCacheCanBeCopiedButReplacementCannotBePromoted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.audio")
        let bytes = Data("original lossless audio fixture".utf8)
        try bytes.write(to: file)
        let cached = try CachedMediaTransfer(url: file, response: URLResponse(url: file, mimeType: "audio/flac", expectedContentLength: bytes.count, textEncodingName: nil))
        let coordinator = MediaTransferCoordinator(), key = key(account: UUID())
        try await coordinator.cache(key) { cached }
        try await coordinator.permanent(key) { value in
            let copy = try #require(await value?.copyForInstallation())
            defer { try? FileManager.default.removeItem(at: copy) }
            #expect(try Data(contentsOf: copy) == bytes)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        try Data("different encoded content".utf8).write(to: file, options: .atomic)
        #expect(await cached.copyForInstallation() == nil)
    }

    @Test func permanentTransferWaitsUntilCancelledCacheHasDrained() async throws {
        let coordinator = MediaTransferCoordinator(), key = key(account: UUID())
        let started = TransferTestSignal(), cancelled = TransferTestSignal(), drain = TransferTestSignal(), events = TransferTestEvents()
        let cache = Task {
            try await coordinator.cache(key) {
                await started.open()
                await withTaskCancellationHandler {
                    await drain.wait() // Models URLSession cancellation completing asynchronously.
                } onCancel: { Task { await cancelled.open() } }
                await events.record("cache drained")
                throw CancellationError()
            }
        }
        await started.wait()
        let permanent = Task {
            try await coordinator.permanent(key) { _ in await events.record("download started") }
        }
        await cancelled.wait()
        #expect(await events.values.isEmpty)
        await drain.open()
        _ = try? await cache.value
        try await permanent.value
        #expect(await events.values == ["cache drained", "download started"])
        #expect(await coordinator.consumerCount(for: key) == 0)
    }

    @Test func cancellingOneConsumerKeepsSharedPermanentTransferAlive() async throws {
        let coordinator = MediaTransferCoordinator(), key = key(account: UUID())
        let started = TransferTestSignal(), finish = TransferTestSignal(), events = TransferTestEvents()
        let first = Task {
            try await coordinator.permanent(key) { _ in
                await events.record("single download")
                await started.open()
                await finish.wait()
                try Task.checkCancellation()
            }
        }
        await started.wait()
        let second = Task {
            try await coordinator.permanent(key) { _ in await events.record("unexpected duplicate") }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.consumerCount(for: key) != 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await coordinator.consumerCount(for: key) == 2)
        first.cancel()
        await finish.open()
        do { try await first.value; Issue.record("Cancelled consumer completed successfully") }
        catch { #expect(error is CancellationError) }
        try await second.value
        #expect(await events.values == ["single download"])
        #expect(await coordinator.consumerCount(for: key) == 0)
    }
}

private actor TransferTestSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private actor TransferTestEvents {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
