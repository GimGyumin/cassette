import Foundation
import SwiftData
import SwiftSonic
import OSLog
import Testing
@testable import Cassette

@Suite("RC audit reproductions", .serialized)
@MainActor
struct RCAuditRegressionTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await condition(), "The controlled request must reach its suspension point")
        try #require(await condition())
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func snapshot() throws -> Starred2 {
        try JSONDecoder().decode(Starred2.self, from: Data(#"{"song":[{"id":"track","title":"Track"}]}"#.utf8))
    }

    @Test func opaqueCacheIDsRemainInsideTheirDirectoryAndDistinct() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheService(modelContainer: try ModelContainer.cassette(inMemory: true), cacheDirectory: directory)
        let sid = UUID()
        var urls = Set<URL>()
        for id in ["folder/track", "../track", "folder_track", "音楽/곡?#"] {
            let url = try await cache.store(data: Data(id.utf8), forSongId: id, serverId: sid, mimeType: "audio/mpeg")
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
            #expect(await cache.cachedURL(forSongId: id, serverId: sid) == url)
            #expect(try Data(contentsOf: url) == Data(id.utf8))
            urls.insert(url)
        }
        #expect(urls.count == 4)
    }

    @Test func oversizedImportIsRejectedBeforeEvictingExistingAudio() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheService(modelContainer: try ModelContainer.cassette(inMemory: true),
            maxBytes: CacheService.minMaxBytes, cacheDirectory: directory)
        let sid = UUID()
        let existing = try await cache.store(data: Data([1, 2, 3]), forSongId: "keep", serverId: sid, mimeType: "audio/flac")
        let source = directory.appendingPathComponent("oversized-source")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(CacheService.minMaxBytes + 1))
        try handle.close()
        await #expect(throws: CocoaError.self) {
            _ = try await cache.store(fileAt: source, forSongId: "keep", serverId: sid, mimeType: "audio/flac")
        }
        #expect(await cache.cachedURL(forSongId: "keep", serverId: sid) == existing)
        #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
        #expect(await cache.trackCount == 1)
        #expect(await cache.usedBytes == 3)
    }

    @Test(arguments: [UInt64.max, UInt64.max - 7, UInt64(15), UInt64(25)])
    func corruptMP4BoxCannotOverflowOrEnterTheDownloadStore(size: UInt64) async throws {
        let directory = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = Data([0, 0, 0, 8, 102, 116, 121, 112, 0, 0, 0, 1, 109, 100, 97, 116])
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: size >> shift)) }
        #expect(AudioFaststartRemuxer.topLevelBoxTypes(in: bytes).isEmpty)
        let file = directory.appendingPathComponent("invalid.mp4")
        try bytes.write(to: file)
        #expect(throws: AudioResponseRejection.self) {
            try AudioResponseValidator.validate(fileAt: file,
                response: URLResponse(url: file, mimeType: "audio/mp4", expectedContentLength: bytes.count, textEncodingName: nil),
                songId: "fixture", logger: Logger(subsystem: "tests", category: "mp4"))
        }
        _ = await AudioFaststartRemuxer().remuxToFaststartIfNeeded(at: file)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func staleFavoriteSnapshotCannotResurrectAnUnstarredSong() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        let server = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        state.activeServer = server
        model.mainContext.insert(FavoriteRecord(itemType: .song, itemId: "track", starredDate: Date(), serverId: server.id))
        try model.mainContext.save()
        let library = SearchLibraryStub()
        library.mutationOperation = { _ in }
        var pending: CheckedContinuation<Starred2, any Error>?
        library.starredOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        let favorites = FavoritesService(libraryService: library, serverState: state, modelContainer: model,
            mediaIdentityService: MediaIdentityService(modelContainer: model))
        let sync = Task { try await favorites.syncFromServer() }
        try await waitUntil { pending != nil }
        try await favorites.unstar(itemType: .song, itemId: "track")
        pending?.resume(returning: try snapshot())
        try await sync.value
        #expect(try ModelContext(model).fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
    }

    @Test func consecutiveFavoriteTapsReachTheServerInOrder() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        let library = SearchLibraryStub()
        var first: CheckedContinuation<Void, Never>?
        var calls: [Bool] = []
        library.mutationOperation = { starred in
            calls.append(starred)
            if calls.count == 1 { await withCheckedContinuation { first = $0 } }
        }
        let favorites = FavoritesService(libraryService: library, serverState: state, modelContainer: model,
            mediaIdentityService: MediaIdentityService(modelContainer: model))
        let star = Task { try await favorites.star(itemType: .song, itemId: "track") }
        try await waitUntil { first != nil }
        let unstar = Task { try await favorites.unstar(itemType: .song, itemId: "track") }
        first?.resume()
        try await star.value
        try await unstar.value
        #expect(calls == [true, false])
        #expect(try ModelContext(model).fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
    }

    @Test func supersededIndexFailureCannotOverwriteASuccessfulBuild() async throws {
        let index = LibraryIndexService()
        let first = SearchLibraryStub()
        var pending: CheckedContinuation<[ArtistIndex], any Error>?
        first.artistsOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        let stale = Task { await index.rebuildAndWait(using: first) }
        try await waitUntil { pending != nil }
        #expect(await index.rebuildAndWait(using: SearchLibraryStub()))
        pending?.resume(throwing: URLError(.cancelled))
        _ = await stale.value
        #expect(index.hasUsableIndex)
        #expect(index.lastError == nil)
    }

    @Test(arguments: [SongListFilter.downloads, .favorites])
    func staleLibraryPageCannotReplaceTheSelectedSource(filter: SongListFilter) async throws {
        let library = SearchLibraryStub()
        var pending: CheckedContinuation<[Song], any Error>?
        library.songsOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        library.starredOperation = { try JSONDecoder().decode(Starred2.self, from: Data("{}".utf8)) }
        let vm = SongsListViewModel(libraryService: library)
        let load = Task { await vm.load() }
        try await waitUntil { pending != nil }
        await vm.setFilter(filter)
        pending?.resume(returning: try snapshot().song ?? [])
        await load.value
        #expect(vm.filter == filter)
        #expect(vm.allSongs.isEmpty)
        #expect(!vm.isLoading && !vm.isLoadingFilterSource)
    }

    @Test func shuffleRestoreRetainsInsertedSongsAndDuplicateOccurrences() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let player = try #require(container.playerService as? PlayerService)
        let a = DisplayableSong(id: "a", title: "A"), b = DisplayableSong(id: "b", title: "B")
        let c = DisplayableSong(id: "c", title: "C"), d = DisplayableSong(id: "d", title: "D")
        container.playerState.queue = [a, b, c]
        container.playerState.currentTrack = a
        container.playerState.currentIndex = 0
        await player.toggleShuffle()
        await player.addToQueue(d)
        await player.playNext([b, b])
        await player.toggleShuffle()
        #expect(container.playerState.queue.map(\.id) == ["a", "b", "b", "b", "c", "d"])
        await player.stop()
    }

    @Test func playNextMovesTheAutoplayBoundaryBeforeRepeatTruncation() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let player = try #require(container.playerService as? PlayerService)
        let songs = ["a", "b", "c", "d"].map { DisplayableSong(id: $0, title: $0) }
        container.playerState.queue = songs
        container.playerState.currentTrack = songs[0]
        container.playerState.currentIndex = 0
        container.playerState.originalQueueEndIndex = 2
        container.playerState.repeatMode = .off
        await player.playNext(DisplayableSong(id: "x", title: "X"))
        #expect(container.playerState.originalQueueEndIndex == 3)
        await player.setRepeatMode(.all)
        #expect(container.playerState.queue.map(\.id) == ["a", "x", "b"])
        await player.stop()
    }

    @Test(arguments: [false, true])
    func transportChangeInvalidatesAnUnfinishedSessionRestore(selectNewTrack: Bool) async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = RCHeldRestoreResolver()
        let config = ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test")
        container.serverState.activeServer = ServerSnapshot(from: config)
        let player = PlayerService(state: container.playerState, mediaResolver: resolver,
            serverService: container.serverService, sessionService: container.sessionService,
            artworkImageCache: container.artworkImageCache, lyricsService: container.lyricsService,
            libraryService: container.libraryService, cacheService: container.cacheService,
            downloadService: container.downloadService, cacheSettings: container.cacheSettings,
            streamingSettings: container.streamingSettings, replayGainSettings: container.replayGainSettings,
            crossfadeSettings: container.crossfadeSettings, gaplessSettings: container.gaplessSettings,
            toastService: container.toastService, statsService: container.statsService,
            listenBrainzService: container.listenBrainzService, engine: engine)
        let track = DisplayableSong(id: "a", title: "A")
        await container.sessionService.save(playerState: SessionPayload(currentIndex: 0, currentPosition: 45,
            queue: [track], currentTrack: track, repeatMode: .off),
            identity: PlaybackCheckpointIdentity(accountID: config.id, trackID: track.id, queueIndex: 0, revision: "fixture"))
        let restore = Task { await player.restoreSession() }
        try await waitUntil { resolver.pending != nil }
        let replacementURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SilentMP3.mp3")
        if selectNewTrack {
            resolver.followUpSource = .downloaded(replacementURL)
            try await player.play(tracks: [DisplayableSong(id: "b", title: "B")], startIndex: 0)
            #expect(await player.isRestoringSession == false)
        } else { await player.stop() }
        resolver.pending?.resume(returning: .downloaded(URL(fileURLWithPath: "/tmp/rc-restored.mp3")))
        resolver.pending = nil
        await restore.value
        #expect(await player.currentSource?.url == (selectNewTrack ? replacementURL : nil))
        #expect(await player.pendingRestoreInfo == nil)
        if selectNewTrack { #expect(container.playerState.currentTrack?.id == "b") }
        else {
            #expect(container.playerState.playbackState == .idle)
            #expect(container.playerState.currentTrack == nil)
        }
        await player.stop()
    }

    private func services(at root: URL) throws -> (ModelContainer, MockServerService, RCAuditTransport, DownloadService, PlaylistService) {
        let model = try ModelContainer.cassette(inMemory: true)
        let transport = RCAuditTransport()
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://example.invalid", username: "test"))
        server.musicClient = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://example.invalid")!,
            username: "test", password: "test"), transport: transport, retryPolicy: .none)
        server.credentials = ServerCredentials(password: "test", customHeaders: [:])
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        return (model, server, transport, downloads, PlaylistService(serverService: server, modelContainer: model, downloadService: downloads))
    }

    @Test func offlinePlaylistMutationsPreserveOccurrencesOrderAndServerScope() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, server, _, downloads, playlists) = try services(at: directory)
        let sid = try #require(server.state.activeServer?.id)
        let row = DownloadedPlaylist(playlistId: "shared", serverId: sid, name: "Own", tracksCount: 2,
            totalTracksCount: 2, songIds: ["track", "track"])
        let foreign = DownloadedPlaylist(playlistId: "shared", serverId: UUID(), name: "Foreign", tracksCount: 1,
            totalTracksCount: 1, songIds: ["foreign-track"])
        model.mainContext.insert(row)
        model.mainContext.insert(foreign)
        try model.mainContext.save()
        try await playlists.removeTracks(playlistId: "shared", indices: [0])
        var context = ModelContext(model)
        #expect(try context.fetch(FetchDescriptor<DownloadedPlaylist>()).first { $0.serverId == sid }?.songIds == ["track"])
        #expect(row.songIds == ["track"])
        row.songIds = ["track", "other"]
        try model.mainContext.save()
        try await playlists.reorderTracks(playlistId: "shared", orderedSongIds: ["other", "track"])
        context = ModelContext(model)
        let updated = try #require(context.fetch(FetchDescriptor<DownloadedPlaylist>()).first { $0.serverId == sid })
        #expect(updated.songIds == ["other", "track"])
        #expect(row.songIds == ["other", "track"])
        model.mainContext.delete(row)
        try model.mainContext.save()
        try await playlists.addTracks(playlistId: "shared", songs: try snapshot().song ?? [])
        #expect(try ModelContext(model).fetch(FetchDescriptor<DownloadedPlaylist>()).first?.songIds == ["foreign-track"])
        await downloads.cancelAllDownloads()
    }

    @Test func unstarInvalidatesTheCachedServerSnapshot() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, server, transport, downloads, _) = try services(at: directory)
        let library = LibraryService(serverService: server, modelContainer: model, downloadService: downloads,
            statsService: StatsService(modelContainer: model))
        #expect(try await library.getStarred2().song?.count == 1)
        try await library.unstar(songIds: ["track"], albumIds: [], artistIds: [])
        #expect(try await library.getStarred2().song?.isEmpty == true)
        #expect(await transport.starred == false)
        await downloads.cancelAllDownloads()
    }

    @Test func staleStarredRequestCannotRepopulateCacheAfterUnstar() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, server, transport, downloads, _) = try services(at: directory)
        let library = LibraryService(serverService: server, modelContainer: model, downloadService: downloads,
            statsService: StatsService(modelContainer: model))
        await transport.holdNextStarred()
        let stale = Task { try await library.getStarred2() }
        try await waitUntil { await transport.isHeld }
        try await library.unstar(songIds: ["track"], albumIds: [], artistIds: [])
        await transport.release()
        await #expect(throws: CancellationError.self, performing: { try await stale.value })
        #expect(try await library.getStarred2().song?.isEmpty == true)
        await downloads.cancelAllDownloads()
    }

    @Test func cancelledDownloadCleanupCannotUntrackItsReplacement() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, server, _, downloads, _) = try services(at: directory)
        let sid = try #require(server.state.activeServer?.id)
        var first: CheckedContinuation<ServerCredentials, any Error>?
        var second: CheckedContinuation<ServerCredentials, any Error>?
        var calls = 0
        server.credentialsOperation = {
            calls += 1
            return try await withCheckedThrowingContinuation { if calls == 1 { first = $0 } else { second = $0 } }
        }
        let song = try #require(snapshot().song?.first)
        let old = Task { try await downloads.download(song: song, serverId: sid) }
        try await waitUntil { first != nil }
        await downloads.cancelDownload(songId: song.id, serverId: sid)
        let replacement = Task { try await downloads.download(song: song, serverId: sid) }
        try await waitUntil { second != nil }
        first?.resume(throwing: URLError(.cancelled))
        _ = await old.result
        #expect(await downloads.isDownloading(songId: song.id, serverId: sid))
        replacement.cancel()
        second?.resume(throwing: URLError(.cancelled))
        _ = await replacement.result
        #expect(await downloads.isDownloading(songId: song.id, serverId: sid) == false)
        await downloads.cancelAllDownloads()
    }

    @Test func aRepairBatchCapturedBeforeCancelCannotStartAfterCancel() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, server, _, downloads, _) = try services(at: directory)
        let sid = try #require(server.state.activeServer?.id)
        let generation = await downloads.currentDownloadGeneration()
        var calls = 0
        server.credentialsOperation = { calls += 1; throw URLError(.unknown) }
        await downloads.cancelAllDownloads()
        await #expect(throws: CancellationError.self) {
            _ = try await downloads.downloadSongs(try snapshot().song ?? [], serverId: sid, generation: generation)
        }
        #expect(calls == 0)
    }

    @Test func reducingThePowerBudgetDrainsWorkBeforeSubmittingAnotherSong() async throws {
        let cool = PerformanceBudget.make(thermalPressure: .nominal, isLowPowerMode: false,
            isAppActive: true, reduceMotion: false, isMemoryPressured: false, liquidGlassOverride: false)
        let hot = PerformanceBudget.make(thermalPressure: .serious, isLowPowerMode: true,
            isAppActive: true, reduceMotion: false, isMemoryPressured: false, liquidGlassOverride: false)
        let budget = PerformanceBudgetStore(cool)
        let probe = RCBatchProbe()
        let batch = Task {
            try await DownloadBatchRunner.run(Array(0..<5), maximumConcurrent: {
                budget.load().maximumConcurrentDownloads
            }) { id in await probe.perform(id) }
        }
        try await waitUntil { await probe.started.count == 3 }
        budget.store(hot)
        await probe.finish(0)
        await probe.finish(1)
        #expect(await probe.started.count == 3)
        await probe.finish(2)
        try await waitUntil { await probe.started.count == 4 }
        #expect(await probe.maximumActive == 3)
        #expect(await probe.active == 1)
        await probe.finish(3)
        try await waitUntil { await probe.started.count == 5 }
        #expect(await probe.active == 1)
        await probe.finish(4)
        #expect(try await batch.value == 5)
    }

    @Test(arguments: [false, true])
    func batchCancellationNeverSubmitsTheRemainingSongs(individual: Bool) async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, server, _, downloads, _) = try services(at: directory)
        let sid = try #require(server.state.activeServer?.id)
        let initial = CassettePerformance.budget.maximumConcurrentDownloads
        var calls = 0
        server.credentialsOperation = {
            calls += 1
            try await Task.sleep(for: .seconds(30))
            throw URLError(.notConnectedToInternet)
        }
        let songs = (0..<8).map { DisplayableSong(id: "batch-\($0)", title: "Batch").asSong() }
        let album = AlbumID3(id: "album", name: "Album", songCount: 8, duration: 480, song: songs)
        let batch = Task { try await downloads.download(album: album, serverId: sid) }
        try await waitUntil { calls == initial }
        if individual { await downloads.cancelAlbumDownload(albumId: album.id, serverId: sid) }
        else { await downloads.cancelAllDownloads() }
        await #expect(throws: CancellationError.self, performing: { try await batch.value })
        #expect(calls == initial)
        #expect(await downloads.isDownloadingAlbum(album.id) == false)
        await downloads.cancelAllDownloads()
    }
}

@MainActor private final class RCHeldRestoreResolver: MediaResolverProtocol {
    var pending: CheckedContinuation<MediaSource, Never>?
    var followUpSource: MediaSource?
    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        if let followUpSource { return followUpSource }
        return await withCheckedContinuation { pending = $0 }
    }
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource { throw URLError(.unknown) }
}

private actor RCAuditTransport: HTTPTransport {
    var starred = true
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    var isHeld: Bool { pending != nil }
    func holdNextStarred() { hold = true }
    func release() { pending?.resume(); pending = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let endpoint = request.url!.deletingPathExtension().lastPathComponent
        var payload: [String: Any] = ["status": "ok", "version": "1.16.1"]
        if endpoint == "getPlaylist" || endpoint == "createPlaylist" {
            payload["playlist"] = ["id": "shared", "name": "Fixture", "songCount": 2, "duration": 120,
                "entry": [["id": "track", "title": "Track"], ["id": "track", "title": "Track"]]]
        }
        if endpoint == "getStarred2" {
            payload["starred2"] = ["song": starred ? [["id": "track", "title": "Track"]] : []]
            if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        }
        if endpoint == "unstar" { starred = false }
        if endpoint == "star" { starred = true }
        return (try JSONSerialization.data(withJSONObject: ["subsonic-response": payload]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private actor RCBatchProbe {
    private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
    private(set) var started: [Int] = []
    private(set) var maximumActive = 0
    var active: Int { pending.count }
    func perform(_ id: Int) async -> Bool {
        await withCheckedContinuation {
            pending[id] = $0
            started.append(id)
            maximumActive = max(maximumActive, pending.count)
        }
    }
    func finish(_ id: Int) { pending.removeValue(forKey: id)?.resume(returning: true) }
}
