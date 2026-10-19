import Foundation
import AVFoundation
import AudioStreaming
import SwiftData
import Testing
import SwiftSonic
@testable import Cassette

@Suite("Unified cached and pinned audio", .serialized) @MainActor
struct UnifiedLocalAudioTests {
    @Test func persistedMatchingTransferSurvivesRestartAndPinSurvivesCacheClear() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appendingPathComponent("cache")
        let cache = CacheService(modelContainer: model, cacheDirectory: cacheDirectory)
        let account = UUID()
        let request = URLRequest(url: URL(string: "https://example.invalid/stream?id=track&format=raw&t=secret")!)
        let key = MediaTransferKey(accountID: account, revision: 1, songID: "track", request: request)
        let source = root.appendingPathComponent("source")
        let bytes = Data("ID3 immutable fixture audio".utf8)
        try bytes.write(to: source)
        let cachedURL = try await cache.storeTransferred(fileAt: source, forSongId: "track", serverId: account,
                                                         mimeType: "audio/mpeg", key: key)
        let reopened = CacheService(modelContainer: model, cacheDirectory: cacheDirectory)
        let transfer = try #require(await reopened.completedTransfer(for: key))
        let staged = try #require(await transfer.copyForInstallation())
        defer { try? FileManager.default.removeItem(at: staged) }
        let pinned = root.appendingPathComponent("downloads/pinned.mp3")
        try LocalAudioFileStore.install(staged, at: pinned, sharesImmutableSource: true)
        #expect(ArtworkContentStore.fileIdentity(cachedURL) == ArtworkContentStore.fileIdentity(pinned))
        var lossyRequest = request
        lossyRequest.url = URL(string: "https://example.invalid/stream?id=track&format=aac&maxBitRate=128")!
        let different = MediaTransferKey(accountID: account, revision: 1, songID: "track", request: lossyRequest)
        #expect(await reopened.completedTransfer(for: different) == nil)
        await reopened.clearAudioTracksOnly()
        #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(try Data(contentsOf: pinned) == bytes)
    }

    @Test func downloadServicePinsPersistedCacheWithoutFetchingAudioAgain() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheService(modelContainer: model, cacheDirectory: root.appendingPathComponent("audio"))
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Fixture", baseURL: "https://example.invalid", username: "u"))
        server.credentials = ServerCredentials(password: "p", customHeaders: [:])
        let client = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://example.invalid")!,
            username: "u", password: "p"), retryPolicy: .none)
        server.musicClient = client
        let account = try #require(server.state.activeServer?.id)
        let identity = try server.state.requestIdentity(for: account)
        let request = URLRequest(url: try #require(client.streamURL(id: "track", format: "raw")))
        let key = MediaTransferKey(accountID: account, revision: identity.revision, songID: "track", request: request)
        let source = root.appendingPathComponent("source")
        let bytes = Data("ID3 immutable fixture audio".utf8)
        try bytes.write(to: source)
        let cached = try await cache.storeTransferred(fileAt: source, forSongId: "track", serverId: account,
                                                      mimeType: "audio/mpeg", key: key)
        let formatKey = "cassette.streaming.download"
        let old = UserDefaults.standard.object(forKey: formatKey)
        UserDefaults.standard.set(CacheFormat.matchStream.rawValue, forKey: formatKey)
        defer { if let old { UserDefaults.standard.set(old, forKey: formatKey) } else { UserDefaults.standard.removeObject(forKey: formatKey) } }
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")),
            storageDirectory: root, cacheService: cache)
        downloads.setOriginalArtworkLoader { _, _ in true }
        let song = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"track","title":"Fixture","suffix":"mp3","duration":3}"#.utf8))
        try await downloads.download(song: song, serverId: account)
        let pinned = try #require(await downloads.downloadedURL(forSongId: "track", serverId: account))
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(await cache.cachedURL(forSongId: "track", serverId: account) == pinned)
        #expect(await cache.usedBytes == Int64(bytes.count))
        #expect(await cache.reclaimableBytes == 0)
        #expect(await cache.trackCount == 1)
        await cache.clearAudioTracksOnly()
        #expect(try Data(contentsOf: pinned) == bytes)
        #expect(await downloads.isDownloaded(songId: "track", serverId: account))
        _ = try await cache.store(data: bytes, forSongId: "recent", serverId: account, mimeType: "audio/mpeg")
        let storage = StorageManagementService(modelContainer: model, cacheService: cache, downloadService: downloads,
            externalArtworkCache: ExternalArtworkCache(cacheDirectory: root.appendingPathComponent("external")),
            artworkImageCache: ArtworkImageCache(downloadService: downloads, libraryService: SearchLibraryStub(), serverService: server),
            dominantColorExtractor: DominantColorExtractor(), coverArtsDirectory: root.appendingPathComponent("coverarts"))
        let categories = await storage.categories()
        #expect(!categories.contains { $0.kind == .downloads })
        let music = try #require(categories.first { $0.kind == .audioCache })
        #expect(music.byteCount == Int64(bytes.count * 2))
        #expect(music.itemCount == 2)
        #expect(await storage.reclaimableAudioBytes == Int64(bytes.count))
        await storage.clear(.audioCache)
        #expect(await cache.trackCount == 1)
        #expect(await cache.cachedURL(forSongId: "track", serverId: account) == pinned)
        do {
            _ = try await cache.store(data: Data("ID3 replacement".utf8), forSongId: "track", serverId: account, mimeType: "audio/mpeg")
            Issue.record("Automatic storage replaced saved audio")
        } catch { #expect(error is CancellationError) }
        #expect(try Data(contentsOf: pinned) == bytes)
        try await downloads.remove(songId: "track", serverId: account)
        #expect(!(await downloads.isDownloaded(songId: "track", serverId: account)))
        #expect(await cache.cachedURL(forSongId: "track", serverId: account) == pinned)
        #expect(await cache.reclaimableBytes == Int64(bytes.count))
        #expect(await cache.completedTransfer(for: key) != nil)
        // The saved file is reused when it is pinned again; no second HTTP transfer is needed.
        try await downloads.download(song: song, serverId: account)
        #expect(await downloads.isDownloaded(songId: "track", serverId: account))
        #expect(await cache.trackCount == 1)
        await downloads.removeAllDownloads()
        #expect(await cache.reclaimableBytes == Int64(bytes.count))
        await cache.clearAudioTracksOnly()
        #expect(!FileManager.default.fileExists(atPath: pinned.path))
        #expect(await cache.trackCount == 0)
    }

    @Test func legacyCacheAndDownloadsMigrateToOneInventoryAndPreservePins() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldCache = root.appendingPathComponent("old-cache"), oldPins = root.appendingPathComponent("old-downloads")
        let shared = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: oldCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldPins, withIntermediateDirectories: true)
        let automatic = Data("ID3 automatic legacy track".utf8), pinned = Data("ID3 pinned original legacy track".utf8)
        try automatic.write(to: oldCache.appendingPathComponent("automatic.mp3"))
        try automatic.write(to: oldCache.appendingPathComponent("duplicate.mp3"))
        try pinned.write(to: oldPins.appendingPathComponent("saved.mp3"))
        let server = UUID(), context = ModelContext(model)
        context.insert(CachedTrack(songId: "automatic", serverId: server, filePath: "automatic.mp3", fileSize: Int64(automatic.count), mimeType: "audio/mpeg"))
        context.insert(CachedTrack(songId: "saved", serverId: server, filePath: "duplicate.mp3", fileSize: Int64(automatic.count), mimeType: "audio/mpeg"))
        context.insert(DownloadedTrack(songId: "saved", serverId: server, filePath: "saved.mp3", fileSize: Int64(pinned.count), mimeType: "audio/mpeg", title: "Saved"))
        try context.save()
        let cache = CacheService(modelContainer: model, cacheDirectory: shared, legacyCacheDirectory: oldCache, legacyDownloadsDirectory: oldPins)
        await cache.prepareUnifiedAudio()
        #expect(await cache.trackCount == 2)
        #expect(await cache.usedBytes == Int64(automatic.count + pinned.count))
        #expect(await cache.reclaimableBytes == Int64(automatic.count))
        let saved = try #require(await cache.cachedURL(forSongId: "saved", serverId: server))
        #expect(saved == shared.appendingPathComponent("saved.mp3"))
        #expect(try Data(contentsOf: saved) == pinned)
        #expect(!FileManager.default.fileExists(atPath: oldPins.appendingPathComponent("saved.mp3").path))
        #expect(!FileManager.default.fileExists(atPath: oldCache.appendingPathComponent("duplicate.mp3").path))
        await cache.clearAll()
        #expect(await cache.trackCount == 1)
        #expect(try Data(contentsOf: saved) == pinned)
        let restarted = CacheService(modelContainer: model, cacheDirectory: shared, legacyCacheDirectory: oldCache, legacyDownloadsDirectory: oldPins)
        #expect(await restarted.cachedURL(forSongId: "saved", serverId: server) == saved)
        #expect(await restarted.trackCount == 1)
    }

    @Test func nativeEngineCanPlayAnImportedM4ACache() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        pcm.frameLength = 44100
        let channels = try #require(pcm.floatChannelData)
        for frame in 0..<44100 {
            let value = Float(0.2 * sin(Double(frame) * 2 * .pi * 440 / 44100))
            channels[0][frame] = value; channels[1][frame] = value
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16])
            try file.write(from: pcm)
        }
        let cache = CacheService(modelContainer: model, cacheDirectory: root.appendingPathComponent("cache"))
        let server = UUID()
        _ = try await cache.store(fileAt: source, forSongId: "m4a", serverId: server, mimeType: "audio/mp4")
        let cached = try #require(await cache.cachedURL(forSongId: "m4a", serverId: server))
        let engine = AVPlayerPlaybackEngine()
        engine.volume = 0
        defer { engine.stop() }
        engine.play(url: cached, headers: [:])
        let deadline = Date().addingTimeInterval(5)
        while engine.progress < 0.2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.progress >= 0.2)
        #expect(engine.state == .playing)
    }

    @Test func failedFileIsEvictedAfterItsRemoteIDChangesWithoutTouchingAnotherAccount() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheService(modelContainer: model, cacheDirectory: root)
        let server = UUID(), other = UUID()
        let bytes = Data("ID3 fixture audio".utf8)
        let failed = try await cache.store(data: bytes, forSongId: "old-id", serverId: server, mimeType: "audio/mpeg")
        let retained = try await cache.store(data: bytes, forSongId: "old-id", serverId: other, mimeType: "audio/mpeg")
        let localStore: any CacheServiceProtocol = cache
        await localStore.invalidate(songId: "new-id", serverId: server, matching: failed)
        #expect(await cache.cachedURL(forSongId: "old-id", serverId: server) == nil)
        #expect(await cache.cachedURL(forSongId: "old-id", serverId: other) == retained)
    }

    @Test func sameSizeStructuredErrorInvalidatesOnlyItsCacheAndRejectedImportKeepsGoodFile() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheService(modelContainer: model, cacheDirectory: root)
        let server = UUID()
        let bytes = Data("ID3 original audio bytes".utf8)
        let url = try await cache.store(data: bytes, forSongId: "bad", serverId: server, mimeType: "audio/mpeg")
        let good = try await cache.store(data: bytes, forSongId: "good", serverId: server, mimeType: "audio/mpeg")
        var poisoned = Data("{\"error\":\"failed\"}".utf8)
        poisoned.append(Data(repeating: 32, count: bytes.count - poisoned.count))
        try poisoned.write(to: url, options: .atomic)
        #expect(await cache.cachedURL(forSongId: "bad", serverId: server) == nil)
        #expect(await cache.cachedURL(forSongId: "good", serverId: server) == good)
        do {
            _ = try await cache.store(data: poisoned, forSongId: "good", serverId: server, mimeType: "audio/mpeg")
            Issue.record("An HTTP error body replaced cached audio")
        } catch { #expect(error is AudioResponseRejection) }
        #expect(try Data(contentsOf: good) == bytes)
        #expect(await cache.trackCount == 1)
    }
}
