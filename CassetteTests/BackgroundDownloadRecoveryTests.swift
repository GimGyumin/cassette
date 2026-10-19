import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Durable background downloads") @MainActor
struct BackgroundDownloadRecoveryTests {
    private func record(server: UUID = UUID()) -> BackgroundDownloadJournal.Record {
        .init(song: DisplayableSong(id: "track", title: "Recovery", audioFormat: "mp3").asSong(),
              serverID: server, format: .matchStream, albumCoverArtID: "album-cover",
              expectedOriginalSize: nil, originalContainer: nil)
    }

    private func stage(_ record: BackgroundDownloadJournal.Record, in journal: BackgroundDownloadJournal,
                       directory: URL) throws -> Data {
        try journal.insert(record)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SilentMP3.mp3")
        let bytes = try Data(contentsOf: source)
        let file = directory.appendingPathComponent("incoming-\(UUID()).mp3")
        try bytes.write(to: file)
        let response = URLResponse(url: URL(string: "https://example.invalid/stream?token=secret")!,
            mimeType: "audio/mpeg", expectedContentLength: bytes.count, textEncodingName: nil)
        _ = try journal.stage(id: record.id, file: file, response: response)
        return bytes
    }

    @Test func completedPayloadAndMetadataSurviveANewJournalInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BackgroundDownloadJournal(directory: root)
        let intent = record()
        let bytes = try stage(intent, in: journal, directory: root)
        let restored = BackgroundDownloadJournal(directory: root)
        let saved = try #require(restored.completed().first)
        #expect(saved.song.title == "Recovery")
        #expect(saved.albumCoverArtID == "album-cover")
        #expect(saved.response.mimeType == "audio/mpeg")
        #expect(try Data(contentsOf: restored.payloadURL(saved.id)) == bytes)
        let metadata = try String(contentsOf: root.appendingPathComponent("\(intent.id.uuidString).json"), encoding: .utf8)
        #expect(!metadata.contains("secret"))
        #expect(!metadata.contains("example.invalid"))
    }

    @Test func incompleteAndCancelledTransfersCannotReappear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BackgroundDownloadJournal(directory: root)
        let intent = record()
        try journal.insert(intent)
        #expect(journal.completed().isEmpty)
        journal.remove(intent.id)
        let file = root.appendingPathComponent("late")
        try Data([1, 2]).write(to: file)
        #expect(throws: (any Error).self) {
            try journal.stage(id: intent.id, file: file, response: URLResponse())
        }
        #expect(journal.completed().isEmpty)
    }

    @Test func relaunchRegistersDownloadsOnceAndResolvesThemOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        server.state.activeServer = snapshot
        server.state.isOnline = false
        let journal = BackgroundDownloadJournal(directory: root.appendingPathComponent("journal"))
        let intent = record(server: snapshot.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try stage(intent, in: journal, directory: root)
        let downloads = DownloadService(serverService: server, modelContainer: model,
            toastService: ToastService(), journal: journal, storageDirectory: root)
        await downloads.recoverBackgroundDownloads()
        await downloads.recoverBackgroundDownloads()
        let rows = try ModelContext(model).fetch(FetchDescriptor<DownloadedTrack>())
        #expect(rows.count == 1)
        #expect(rows.first?.coverArtId == "album-cover")
        let file = try #require(await downloads.downloadedURL(forSongId: "track", serverId: snapshot.id))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(journal.completed().isEmpty)
        let resolver = MediaResolver(downloadService: downloads, cacheService: MockCacheService(),
            serverService: server, serverState: server.state, streamingSettings: StreamingSettings())
        let source = try await resolver.resolve(songId: "track", serverId: snapshot.id, song: nil)
        #expect(source.isLocal)
        #expect(source.url == file)
        #expect(await downloads.downloadedURL(forSongId: "track", serverId: UUID()) == nil)
    }

    @Test func aDifferentAccountCannotImportCompletedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BackgroundDownloadJournal(directory: root)
        _ = try stage(record(), in: journal, directory: root)
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.invalid", username: "test"))
        let downloads = DownloadService(serverService: server, modelContainer: model,
            toastService: ToastService(), journal: journal, storageDirectory: root)
        await downloads.recoverBackgroundDownloads()
        #expect(try ModelContext(model).fetchCount(FetchDescriptor<DownloadedTrack>()) == 0)
        #expect(journal.completed().count == 1)
        await downloads.cancelAllDownloads()
        #expect(journal.completed().isEmpty)
    }

    @Test func targetedLookupPreservesCurrentAndLegacyIDsAndServerScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let file = files.appendingPathComponent("fixture.mp3")
        try Data([1, 2, 3]).write(to: file)
        let model = try ModelContainer.cassette(inMemory: true)
        let serverID = UUID()
        let row = DownloadedTrack(songId: "original", currentRemoteID: "current",
            legacyRemoteIDs: ["historic"], serverId: serverID, filePath: "fixture.mp3",
            fileSize: 3, mimeType: "audio/mpeg", title: "Alias")
        model.mainContext.insert(row)
        try model.mainContext.save()
        let downloads = DownloadService(serverService: MockServerService(), modelContainer: model,
            toastService: ToastService(), journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")),
            storageDirectory: root)
        for id in ["original", "current", "historic"] {
            #expect(await downloads.downloadedURL(forSongId: id, serverId: serverID) == file)
            #expect(await downloads.downloadedURL(forSongId: id, serverId: UUID()) == nil)
        }
        // A stale row cannot make an incomplete file playable.
        try Data([1]).write(to: file)
        #expect(await downloads.downloadedURL(forSongId: "current", serverId: serverID) == nil)
    }

    @Test func progressCallbacksAreBoundedAndCompletionIsImmediate() {
        var throttle = DownloadProgressThrottle()
        var emitted = 0
        for i in 0..<1_000 {
            if throttle.shouldEmit(now: Double(i) / 1_000, received: Int64(i), expected: 1_000) { emitted += 1 }
        }
        #expect(emitted == 4)
        let completed = throttle.shouldEmit(now: 0.999, received: 1_000, expected: 1_000)
        #expect(completed)
    }
}
