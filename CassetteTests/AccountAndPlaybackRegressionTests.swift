import Foundation
import SwiftData
import SwiftSonic
import AudioStreaming
import Testing
@testable import Cassette

@Suite("Account isolation and overlapping playlist edits", .serialized)
@MainActor
struct AccountAndPlaybackRegressionTests {
    private struct Fixture {
        let root: URL
        let model: ModelContainer
        let server: MockServerService
        let transport: AccountAuditTransport
        let downloads: DownloadService
        let playlists: PlaylistService
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        let transport = AccountAuditTransport()
        server.state.activeServer = account("a")
        server.musicClient = client("a", transport: transport)
        server.credentials = ServerCredentials(password: "a", customHeaders: ["X-Account": "a"])
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        return Fixture(root: root, model: model, server: server, transport: transport, downloads: downloads,
            playlists: PlaylistService(serverService: server, modelContainer: model, downloadService: downloads))
    }

    private func account(_ name: String) -> ServerSnapshot {
        ServerSnapshot(from: ServerConfig(displayName: name, baseURL: "https://\(name).example.invalid", username: name))
    }
    private func client(_ name: String, transport: AccountAuditTransport) -> SwiftSonicClient {
        SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://\(name).example.invalid")!,
            username: name, password: name), transport: transport, retryPolicy: .none)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition(), "Request did not reach the controlled suspension point")
    }
    private func viewModel(_ f: Fixture) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(playlistId: "shared", libraryService: SearchLibraryStub(), downloadService: f.downloads,
            playlistService: f.playlists, toastService: ToastService(), serverState: f.server.state)
    }
    private func insertPlaylist(_ f: Fixture, sid: UUID, id: String = "shared", songs: [String]) {
        f.model.mainContext.insert(DownloadedPlaylist(playlistId: id, serverId: sid, name: id,
            tracksCount: songs.count, totalTracksCount: songs.count, songIds: songs))
    }

    @Test func failedDeletionRestoresBeforeTheNextSelectedOccurrenceIsRemoved() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.playlists.getPlaylist(id: "shared")
        let vm = viewModel(f)
        vm.songs = ["a", "b"].map { DisplayableSong(id: $0, title: $0) }
        await f.transport.hold("updatePlaylist", failing: true)
        let first = Task { await vm.removeTrack(at: 1) }
        try await waitUntil { await f.transport.isHeld }
        let second = Task { await vm.removeTrack(at: 0) }
        await Task.yield()
        await f.transport.release()
        await first.value
        await second.value
        #expect(vm.songs.map(\.id) == ["b"])
        #expect(await f.transport.removedIndices == [[1], [0]])
    }

    @Test func queuedReorderRetainsDuplicateOccurrencesAfterDeletionRollback() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.playlists.getPlaylist(id: "shared")
        let vm = viewModel(f)
        vm.songs = ["a", "b", "b"].map { DisplayableSong(id: $0, title: $0) }
        await f.transport.hold("updatePlaylist", failing: true)
        let first = Task { await vm.removeTrack(at: 0) }
        try await waitUntil { await f.transport.isHeld }
        let move = Task { await vm.moveTracks(from: IndexSet(integer: 1), to: 0) }
        await Task.yield()
        await f.transport.release()
        await first.value
        await move.value
        #expect(vm.songs.map(\.id) == ["a", "b", "b"])
        #expect(await f.transport.reorderedIDs == [["a", "b", "b"]])
    }

    @Test func detailDownloadRemovalPreservesPlaylistAndAlbumSharedFiles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        let ids = ["playlist-shared", "album-shared", "exclusive"]
        for id in ids {
            let name = id + ".mp3"
            try Data([1, 2, 3]).write(to: f.root.appendingPathComponent("downloads").appendingPathComponent(name))
            f.model.mainContext.insert(DownloadedTrack(songId: id, serverId: sid,
                albumId: id == "album-shared" ? "album" : nil, filePath: name,
                fileSize: 3, mimeType: "audio/mpeg", title: id))
        }
        insertPlaylist(f, sid: sid, songs: ids)
        insertPlaylist(f, sid: sid, id: "other", songs: ["playlist-shared"])
        f.model.mainContext.insert(DownloadedAlbum(albumId: "album", serverId: sid, name: "Album", tracksCount: 1, totalTracksCount: 1))
        try f.model.mainContext.save()
        let vm = viewModel(f)
        vm.songs = ids.map { DisplayableSong(id: $0, title: $0, isDownloaded: true) }
        await vm.deleteDownload()
        #expect(await f.downloads.downloadedSongIds(serverId: sid) == Set(ids.prefix(2)))
        #expect(vm.songs.map(\.isDownloaded) == [true, true, false])
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads/playlist-shared.mp3").path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads/album-shared.mp3").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads/exclusive.mp3").path))
    }

    @Test(arguments: [false, true])
    func delayedDeletionCannotPurgeAnotherAccountOrAReopenedSession(switchBack: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try #require(f.server.state.activeServer)
        let other = account("b")
        insertPlaylist(f, sid: original.id, songs: ["a"])
        insertPlaylist(f, sid: other.id, songs: ["b"])
        try f.model.mainContext.save()
        await f.transport.hold("deletePlaylist")
        let deletion = Task { try await f.playlists.deletePlaylist(id: "shared", purgeDownloads: true) }
        try await waitUntil { await f.transport.isHeld }
        f.server.state.activeServer = other
        if switchBack { f.server.state.activeServer = original }
        await f.transport.release()
        await #expect(throws: CancellationError.self) { try await deletion.value }
        #expect(try ModelContext(f.model).fetchCount(FetchDescriptor<DownloadedPlaylist>()) == 2)
    }

    @Test func creationDoesNotSendTheDescriptionToANewAccount() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.transport.hold("createPlaylist")
        let creation = Task { try await f.playlists.createPlaylist(name: "New", description: "Description") }
        try await waitUntil { await f.transport.isHeld }
        f.server.state.activeServer = account("b")
        f.server.musicClient = client("b", transport: f.transport)
        await f.transport.release()
        await #expect(throws: CancellationError.self) { try await creation.value }
        #expect(await f.transport.endpoints == ["createPlaylist"])
    }

    @Test func staleReadCannotCacheADeletedPlaylist() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Warm the client so this test isolates content revision from client initialization.
        _ = try await f.playlists.listPlaylists()
        await f.transport.hold("getPlaylist")
        let read = Task { try await f.playlists.getPlaylist(id: "shared") }
        try await waitUntil { await f.transport.isHeld }
        try await f.playlists.deletePlaylist(id: "shared", purgeDownloads: false)
        await f.transport.release()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test(arguments: [false, true])
    func streamContextRejectsHeadersFromAnAccountSwitch(switchBack: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try #require(f.server.state.activeServer)
        var pending: CheckedContinuation<ServerCredentials, any Error>?
        f.server.credentialsOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        let resolver = MediaResolver(downloadService: f.downloads,
            cacheService: CacheService(modelContainer: f.model, cacheDirectory: f.root.appendingPathComponent("cache")),
            serverService: f.server, serverState: f.server.state, streamingSettings: StreamingSettings())
        let request = Task { try await resolver.resolve(songId: "track", serverId: original.id, song: nil) }
        try await waitUntil { pending != nil }
        f.server.state.activeServer = account("b")
        f.server.musicClient = client("b", transport: f.transport)
        if switchBack { f.server.state.activeServer = original }
        pending?.resume(returning: ServerCredentials(password: "b", customHeaders: ["X-Account": "b"]))
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test func stableStreamContextRetainsTheMatchingURLAndHeaders() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let resolver = MediaResolver(downloadService: f.downloads,
            cacheService: CacheService(modelContainer: f.model, cacheDirectory: f.root.appendingPathComponent("cache")),
            serverService: f.server, serverState: f.server.state, streamingSettings: StreamingSettings())
        let source = try await resolver.resolve(songId: "track", serverId: try #require(f.server.state.activeServer?.id), song: nil)
        #expect(source.url.host == "a.example.invalid")
        #expect(source.customHeaders == ["X-Account": "a"])
    }

    @Test func productionClientConstructionNeverJoinsAnotherAccountsFlight() async throws {
        let model = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        let a = account("a"), b = account("b")
        let keychain = MockKeychain()
        for server in [a, b] {
            try await keychain.store(ServerCredentials(password: server.username, customHeaders: ["X-Account": server.username]),
                forKey: ServerCredentials.keychainKey(for: server.id))
        }
        var pending: CheckedContinuation<Void, Never>?
        keychain.retrieveOperation = { key in
            if key == ServerCredentials.keychainKey(for: a.id) { await withCheckedContinuation { pending = $0 } }
        }
        let service = ServerService(state: state, keychain: keychain, modelContainer: model, cacheService: MockCacheService())
        state.activeServer = a
        let first = Task { try await service.makeSwiftSonicClient() }
        try await waitUntil { pending != nil }
        state.activeServer = b
        let context = try await service.requestContext(serverID: b.id)
        #expect(context.client.streamURL(id: "track")?.host == "b.example.invalid")
        #expect(context.credentials.customHeaders == ["X-Account": "b"])
        pending?.resume()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test(arguments: [false, true])
    func favoriteRollbackOnlyRestoresWithinTheOriginalSession(logout: Bool) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        f.model.mainContext.insert(FavoriteRecord(itemType: .song, itemId: "track", starredDate: Date(), serverId: sid))
        try f.model.mainContext.save()
        let library = SearchLibraryStub()
        var pending: CheckedContinuation<Void, any Error>?
        library.mutationOperation = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let favorites = FavoritesService(libraryService: library, serverState: f.server.state, modelContainer: f.model,
            mediaIdentityService: MediaIdentityService(modelContainer: f.model))
        let request = Task { try await favorites.unstar(itemType: .song, itemId: "track") }
        try await waitUntil { pending != nil }
        if logout {
            f.server.state.isSigningOut = true
            f.server.state.activeServer = nil
            for row in try f.model.mainContext.fetch(FetchDescriptor<FavoriteRecord>()) { f.model.mainContext.delete(row) }
            try f.model.mainContext.save()
        }
        pending?.resume(throwing: URLError(.cannotConnectToHost))
        if logout { await #expect(throws: CancellationError.self) { try await request.value } }
        else { await #expect(throws: URLError.self) { try await request.value } }
        #expect(try ModelContext(f.model).fetchCount(FetchDescriptor<FavoriteRecord>()) == (logout ? 0 : 1))
    }

    @Test func playbackConfirmationPreparesNextWithoutTheOldPollingDelay() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let player = try #require(container.playerService as? PlayerService)
        let sid = account("local").id
        let config = ServerConfig(id: sid, displayName: "Local", baseURL: "https://local.example.invalid", username: "test")
        container.serverState.activeServer = ServerSnapshot(from: config)
        let first = DisplayableSong(id: "first", title: "First", duration: 180)
        let next = DisplayableSong(id: "next", title: "Next", duration: 180)
        let firstURL = try await container.cacheService.store(data: Data("ID3 current fixture audio".utf8), forSongId: "first", serverId: sid, mimeType: "audio/mpeg")
        let url = try await container.cacheService.store(data: Data("ID3 next fixture audio".utf8), forSongId: "next", serverId: sid, mimeType: "audio/mpeg")
        await player.installLocalGaplessFixture(firstURL)
        container.playerState.queue = [first, next]
        container.playerState.currentIndex = 0
        container.playerState.currentTrack = first
        container.playerState.repeatMode = .off
        container.playerState.playbackState = .loading
        engine.state = .bufferring
        await player.ensureGaplessPreparation()
        #expect(await player.gaplessPreparationTask == nil)
        engine.state = .playing
        let start = ContinuousClock.now
        await player.publishEnginePlaybackConfirmation()
        try await waitUntil { engine.calls.contains(.queue(url, [:])) }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(container.playerState.playbackState == .playing)
        container.playerState.duration = 180
        container.playerState.position = 175
        await player.enableCrossfadeForPrefetchRegression()
        await player.checkPrefetchThreshold()
        #expect(await player.prefetchScheduled == false, "An armed gapless stream must not launch a second full-file transfer")
        await player.stop()
        await container.cacheService.invalidate(songId: "first", serverId: sid)
        await container.cacheService.invalidate(songId: "next", serverId: sid)
    }
}

private extension PlayerService {
    func installLocalGaplessFixture(_ url: URL) { currentSource = .cached(url) }
    func enableCrossfadeForPrefetchRegression() {
        crossfadeConfig = CrossfadeConfig(duration: 8, disableForGapless: true)
    }
}

private actor AccountAuditTransport: HTTPTransport {
    private var heldEndpoint: String?
    private var failHeld = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var endpoints: [String] = []
    private(set) var removedIndices: [[Int]] = []
    private(set) var reorderedIDs: [[String]] = []
    var isHeld: Bool { pending != nil }
    func hold(_ endpoint: String, failing: Bool = false) { heldEndpoint = endpoint; failHeld = failing }
    func release() { pending?.resume(); pending = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let endpoint = url.deletingPathExtension().lastPathComponent
        endpoints.append(endpoint)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let removes = query.filter { $0.name == "songIndexToRemove" }.compactMap { $0.value.flatMap(Int.init) }
        if !removes.isEmpty { removedIndices.append(removes) }
        let songs = query.filter { $0.name == "songId" }.compactMap(\.value)
        if endpoint == "createPlaylist", !songs.isEmpty { reorderedIDs.append(songs) }
        var payload: [String: Any] = ["status": "ok", "version": "1.16.1"]
        if endpoint == "getPlaylists" { payload["playlists"] = ["playlist": []] }
        if endpoint == "getPlaylist" || endpoint == "createPlaylist" {
            payload["playlist"] = ["id": "shared", "name": "Fixture", "songCount": 2, "duration": 120,
                "entry": [["id": "a", "title": "A"], ["id": "b", "title": "B"]]]
        }
        if endpoint == heldEndpoint {
            heldEndpoint = nil
            if failHeld { payload = ["status": "failed", "version": "1.16.1", "error": ["code": 0, "message": "Fixture failure"]] }
            await withCheckedContinuation { pending = $0 }
        }
        return (try JSONSerialization.data(withJSONObject: ["subsonic-response": payload]),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
