import Foundation
import SwiftData
import SwiftSonic
import Testing
import Synchronization
@testable import Cassette

@Suite("Account-scoped caches and offline file truth", .serialized)
@MainActor
struct IsolationAndOfflineRegressionTests {
    private struct Fixture {
        let root: URL
        let model: ModelContainer
        let server: MockServerService
        let transport: IsolationTransport
        let identity: MediaIdentityService
        let downloads: DownloadService
        let library: LibraryService
        let radio: RadioService
    }
    private func account(_ name: String) -> ServerSnapshot {
        ServerSnapshot(from: ServerConfig(displayName: name, baseURL: "https://\(name).example.invalid", username: name))
    }
    private func activate(_ name: String, _ f: Fixture, snapshot: ServerSnapshot? = nil) {
        f.server.state.activeServer = snapshot ?? account(name)
        f.server.musicClient = SwiftSonicClient(configuration: ServerConfiguration(
            serverURL: URL(string: "https://\(name).example.invalid")!, username: name, password: name),
            transport: f.transport, retryPolicy: .none)
        f.server.credentials = ServerCredentials(password: name, customHeaders: ["X-Account": name])
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        let transport = IsolationTransport()
        let identity = MediaIdentityService(modelContainer: model)
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            mediaIdentityService: identity, journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        let result = Fixture(root: root, model: model, server: server, transport: transport, identity: identity,
            downloads: downloads, library: LibraryService(serverService: server, modelContainer: model,
                downloadService: downloads, statsService: StatsService(modelContainer: model)), radio: RadioService(serverService: server))
        activate("a", result)
        return result
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }
    private func read(_ endpoint: String, _ f: Fixture) async throws -> String? {
        switch endpoint {
        case "getArtist": return try await f.library.artist(id: "same").name
        case "getArtistInfo2": return try await f.library.getArtistInfo(forArtistID: "same", count: 1).musicBrainzId
        case "getAlbumList2": return try await f.library.allAlbums().first?.name
        case "getStarred2": return try await f.library.getStarred2().song?.first?.title
        case "getInternetRadioStations": return try await f.radio.listStations().first?.name
        default: return try await f.library.album(id: "same").name
        }
    }

    private func storage(_ f: Fixture) -> StorageManagementService {
        StorageManagementService(modelContainer: f.model, cacheService: MockCacheService(), downloadService: f.downloads,
            externalArtworkCache: ExternalArtworkCache(cacheDirectory: f.root.appendingPathComponent("external")),
            artworkImageCache: ArtworkImageCache(downloadService: f.downloads, libraryService: f.library, serverService: f.server),
            dominantColorExtractor: DominantColorExtractor(), coverArtsDirectory: f.root.appendingPathComponent("coverarts"))
    }

    @Test func personalMixesDoNotCarryAnOldAccountsTracksIntoANewBuild() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try #require(f.server.state.activeServer)
        let mixes = PersonalMixService(libraryService: f.library, statsService: StatsService(modelContainer: f.model), serverState: f.server.state)
        #expect(await mixes.mixes(serverId: a.id.uuidString, limit: 1).first?.tracks.first?.id == "a-0")
        activate("b", f)
        let b = try #require(f.server.state.activeServer)
        #expect(await mixes.mixes(serverId: b.id.uuidString, limit: 1).first?.tracks.first?.id == "b-0")
        activate("a", f, snapshot: a)
        await f.transport.hold(host: "a", endpoint: "getAlbum")
        let old = Task { await mixes.mix(kind: .newMusic, serverId: a.id.uuidString, forceRefresh: true) }
        try await waitUntil { await f.transport.isHeld(host: "a", endpoint: "getAlbum") }
        activate("b", f, snapshot: b)
        #expect(await mixes.mixes(serverId: b.id.uuidString, limit: 1).first?.tracks.first?.id == "b-0")
        await f.transport.release(host: "a", endpoint: "getAlbum")
        #expect(await old.value == nil)
        #expect(await mixes.mixes(serverId: b.id.uuidString, limit: 1).first?.tracks.first?.id == "b-0")
    }

    @Test func clearingArtworkIncludesPreparedOriginalsButPreservesOfflineDownloadCovers() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        for id in ["same", "same@thumb", "same@hero", "same@original-v1"] {
            await f.downloads.persistCover(Data([1]), forId: id, serverId: sid)
        }
        let original = try #require(await f.downloads.localCoverArtURL(forId: "same@original-v1", serverId: sid))
        let thumb = try #require(await f.downloads.localCoverArtURL(forId: "same@thumb", serverId: sid))
        await storage(f).clear(.artwork)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        let offline = await f.downloads.localCoverArtURL(forId: "same", serverId: sid)
        #expect(offline != nil)
    }

    @Test(arguments: ["getAlbum", "getArtist", "getArtistInfo2", "getAlbumList2", "getStarred2", "getInternetRadioStations"])
    func lateResponsesCannotReplaceTheNewAccountsCache(endpoint: String) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.transport.hold(host: "a", endpoint: endpoint)
        let old = Task { try await read(endpoint, f) }
        try await waitUntil { await f.transport.isHeld(host: "a", endpoint: endpoint) }
        activate("b", f)
        #expect(try await read(endpoint, f) == "b")
        await f.transport.release(host: "a", endpoint: endpoint)
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(try await read(endpoint, f) == "b")
    }

    @Test func anOldFlightCannotRemoveTheNewAccountsPendingFlight() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.transport.hold(host: "a", endpoint: "getAlbum")
        let a = Task { try await f.library.album(id: "same") }
        try await waitUntil { await f.transport.isHeld(host: "a", endpoint: "getAlbum") }
        activate("b", f)
        await f.transport.hold(host: "b", endpoint: "getAlbum")
        let b = Task { try await f.library.album(id: "same") }
        try await waitUntil { await f.transport.isHeld(host: "b", endpoint: "getAlbum") }
        await f.transport.release(host: "a", endpoint: "getAlbum")
        _ = await a.result
        let joined = Task { try await f.library.album(id: "same") }
        await Task.yield()
        await f.transport.release(host: "b", endpoint: "getAlbum")
        #expect(try await b.value.name == "b")
        #expect(try await joined.value.name == "b")
        #expect(await f.transport.count(host: "b", endpoint: "getAlbum") == 1)
    }

    @Test func shortPagesContinueAndRepeatingPagesStopWithoutARequestStorm() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.transport.setPaging(repeating: false)
        #expect(try await f.library.allAlbums().map(\.id) == ["1", "2", "3", "4"])
        #expect(await f.transport.count(host: "a", endpoint: "getAlbumList2") == 3)
        await f.library.invalidateClientCache()
        await f.transport.setPaging(repeating: true)
        #expect(try await f.library.allAlbums().map(\.id) == ["1", "2"])
        #expect(await f.transport.count(host: "a", endpoint: "getAlbumList2") == 5)
    }

    @Test func pinsWithTheSameRemoteIDRemainIndependentAndLegacyRowsRemainReadable() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try #require(f.server.state.activeServer)
        let legacy = PinnedItem(itemType: .album, itemId: "same", displayName: "A", displaySubtitle: "", coverArtId: nil, serverId: a.id, sortOrder: 0)
        legacy.id = "album:same"
        f.model.mainContext.insert(legacy)
        try f.model.mainContext.save()
        let pins = PinService(modelContainer: f.model, serverState: f.server.state)
        #expect(pins.isPinned(itemType: .album, itemId: "same"))
        activate("b", f)
        let b = try #require(f.server.state.activeServer)
        #expect(!pins.isPinned(itemType: .album, itemId: "same"))
        #expect(pins.currentPinnedCount() == 0)
        try pins.pin(itemType: .album, itemId: "same", displayName: "B", displaySubtitle: "", coverArtId: nil, serverId: b.id)
        #expect(pins.currentPinnedCount() == 1)
        #expect(try ModelContext(f.model).fetchCount(FetchDescriptor<PinnedItem>()) == 2)
        pins.unpin(itemType: .album, itemId: "same")
        activate("a", f, snapshot: a)
        #expect(pins.isPinned(itemType: .album, itemId: "same"))
        #expect(try ModelContext(f.model).fetchCount(FetchDescriptor<PinnedItem>()) == 1)
    }

    @Test func opaqueCoverIDsAndRAMImagesAreScopedToTheAccount() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try #require(f.server.state.activeServer)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        let id = "../folder/커버?name"
        await f.downloads.persistCover(png, forId: id, serverId: a.id)
        let aURL = try #require(await f.downloads.localCoverArtURL(forId: id, serverId: a.id))
        #expect(aURL.deletingLastPathComponent() == f.root.appendingPathComponent("coverarts", isDirectory: true))
        let cache = ArtworkImageCache(downloadService: f.downloads, libraryService: f.library, serverService: f.server)
        #expect(await cache.load(coverArtId: id, allowNetwork: false) != nil)
        #expect(cache.cached(for: id) != nil)
        activate("b", f)
        let b = try #require(f.server.state.activeServer)
        #expect(cache.cached(for: id) == nil)
        #expect(await f.downloads.localCoverArtURL(forId: id, serverId: b.id) == nil)
        await f.downloads.persistCover(png, forId: id, serverId: b.id)
        let bURL = try #require(await f.downloads.localCoverArtURL(forId: id, serverId: b.id))
        #expect(aURL != bURL)
        await f.downloads.removeCover(forId: id, serverId: b.id)
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(!FileManager.default.fileExists(atPath: bURL.path))
    }

    @Test func aLateArtworkCredentialResponseCannotSendMixedHeadersOrFillRAM() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IsolationImageProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        IsolationImageProtocol.reset()
        let cache = ArtworkImageCache(downloadService: f.downloads, libraryService: f.library, serverService: f.server, session: session)
        var pending: CheckedContinuation<ServerCredentials, any Error>?
        f.server.credentialsOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        let load = Task { await cache.load(coverArtId: "same", playbackPriority: true) }
        try await waitUntil { pending != nil }
        activate("b", f)
        pending?.resume(returning: ServerCredentials(password: "b", customHeaders: ["X-Account": "b"]))
        #expect(await load.value == nil)
        #expect(IsolationImageProtocol.requestCount == 0)
        #expect(cache.cached(for: "same") == nil)
    }

    @Test func legacyCoverMigrationRequiresAnUnambiguousOwnerAndGCPreservesOtherAccounts() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try #require(f.server.state.activeServer)
        let directory = f.root.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("legacy"))
        f.model.mainContext.insert(DownloadedAlbum(albumId: "album", serverId: a.id, name: "A", tracksCount: 0, totalTracksCount: 1, coverArtId: "legacy"))
        try f.model.mainContext.save()
        let migrated = try #require(await f.downloads.localCoverArtURL(forId: "legacy", serverId: a.id))
        #expect(migrated.lastPathComponent.hasPrefix(a.id.uuidString))
        activate("b", f)
        let b = try #require(f.server.state.activeServer)
        #expect(await f.downloads.localCoverArtURL(forId: "legacy", serverId: b.id) == nil)
        await f.downloads.persistCover(Data([2]), forId: "same", serverId: b.id)
        let bCover = try #require(await f.downloads.localCoverArtURL(forId: "same", serverId: b.id))
        activate("a", f, snapshot: a)
        _ = await f.downloads.garbageCollectOrphanedCovers(referencedIds: [])
        #expect(FileManager.default.fileExists(atPath: bCover.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("legacy").path))
    }

    @Test func missingTruncatedAndEmptyFilesDoNotCountAsOfflineDownloads() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        let cases: [(String, Data?, Int64)] = [("valid", Data([1, 2]), 2), ("missing", nil, 2), ("empty", Data(), 2), ("truncated", Data([1]), 2), ("legacy", Data([1]), 0)]
        for (id, data, size) in cases {
            if let data { try data.write(to: f.root.appendingPathComponent("downloads/" + id)) }
            f.model.mainContext.insert(DownloadedTrack(songId: id, serverId: sid, albumId: "album", filePath: id, fileSize: size, mimeType: "audio/mpeg", title: id))
        }
        f.model.mainContext.insert(DownloadedAlbum(albumId: "album", serverId: sid, name: "Album", tracksCount: 5, totalTracksCount: 5))
        f.model.mainContext.insert(DownloadedPlaylist(playlistId: "list", serverId: sid, name: "List", tracksCount: 6, totalTracksCount: 6, songIds: ["missing", "valid", "valid", "empty", "truncated", "legacy"]))
        try f.model.mainContext.save()
        #expect(await f.downloads.downloadedSongIds(serverId: sid) == Set(["valid", "legacy"]))
        #expect(await f.downloads.localPlaylistData(playlistId: "list", serverId: sid)?.songs.map(\.id) == ["valid", "valid", "legacy"])
        #expect(await f.downloads.localAlbumData(albumId: "album", serverId: sid)?.songs.count == 2)
        let songs = SongsListViewModel(libraryService: f.library, modelContainer: f.model,
            serverState: f.server.state, downloadService: f.downloads)
        await songs.setFilter(.downloads)
        #expect(Set(songs.allSongs.map(\.id)) == Set(["valid", "legacy"]))
        let context = ModelContext(f.model)
        #expect(try context.fetch(FetchDescriptor<DownloadedAlbum>()).first?.tracksCount == 2)
        #expect(try context.fetch(FetchDescriptor<DownloadedPlaylist>()).first?.tracksCount == 3)
    }

    @Test func aThousandTrackPlaylistPreservesOrderDuplicatesAndAliasMappings() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        for i in 0..<1_000 {
            let id = "track-\(i)"
            try Data([1]).write(to: f.root.appendingPathComponent("downloads/" + id))
            f.model.mainContext.insert(DownloadedTrack(songId: id, serverId: sid, albumId: "album", filePath: id, fileSize: 1, mimeType: "audio/mpeg", title: id))
        }
        let ordered = ["old-zero"] + (0..<1_000).reversed().map { "track-\($0)" } + ["track-999"]
        f.model.mainContext.insert(DownloadedPlaylist(playlistId: "large", serverId: sid, name: "Large", tracksCount: ordered.count, totalTracksCount: ordered.count, songIds: ordered))
        try f.model.mainContext.save()
        #expect(f.identity.registerAlias(oldID: "old-zero", newID: "track-0", serverId: sid, entityType: .song, verificationSource: .serverResponse, confidence: 1))
        let start = ContinuousClock.now
        let result = await f.downloads.localPlaylistData(playlistId: "large", serverId: sid)
        print("1,000-track offline playlist lookup: \(start.duration(to: .now))")
        let expected = ["track-0"] + (0..<1_000).reversed().map { "track-\($0)" } + ["track-999"]
        #expect(result?.songs.map(\.id) == expected)
    }

    @Test func albumCompletionCountsFollowVerifiedAliasesAndCoversDisappearOnLogout() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        try Data([1]).write(to: f.root.appendingPathComponent("downloads/track"))
        f.model.mainContext.insert(DownloadedTrack(songId: "track", serverId: sid, albumId: "current-album",
            filePath: "track", fileSize: 1, mimeType: "audio/mpeg", title: "Track"))
        f.model.mainContext.insert(DownloadedAlbum(albumId: "old-album", serverId: sid, name: "Album", tracksCount: 0, totalTracksCount: 1))
        try f.model.mainContext.save()
        #expect(f.identity.registerAlias(oldID: "old-album", newID: "current-album", serverId: sid,
            entityType: .album, verificationSource: .serverResponse, confidence: 1))
        #expect(await f.downloads.downloadedSongIds(serverId: sid) == ["track"])
        #expect(try ModelContext(f.model).fetch(FetchDescriptor<DownloadedAlbum>()).first?.isComplete == true)
        #expect(await f.downloads.localAlbumData(albumId: "old-album", serverId: sid)?.songs.map(\.id) == ["track"])
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        await f.downloads.persistCover(png, forId: "cover")
        let cache = ArtworkImageCache(downloadService: f.downloads, libraryService: f.library, serverService: f.server)
        #expect(await cache.load(coverArtId: "cover", allowNetwork: false) != nil)
        f.server.state.activeServer = nil
        #expect(cache.cached(for: "cover") == nil)
        #expect(await cache.load(coverArtId: "cover", allowNetwork: false) == nil)
    }

    @Test func clearingDownloadsDrainsOldWorkAndRemovesOrphanPlaylistRecords() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        try Data([1]).write(to: f.root.appendingPathComponent("downloads/old"))
        f.model.mainContext.insert(DownloadedTrack(songId: "old", serverId: sid, filePath: "old", fileSize: 1, mimeType: "audio/mpeg", title: "Old"))
        f.model.mainContext.insert(DownloadedAlbum(albumId: "album", serverId: sid, name: "Album", tracksCount: 1, totalTracksCount: 1))
        f.model.mainContext.insert(DownloadedPlaylist(playlistId: "orphan", serverId: sid, name: "Orphan", tracksCount: 0, totalTracksCount: 1, songIds: []))
        try f.model.mainContext.save()
        var pending: CheckedContinuation<ServerCredentials, any Error>?
        f.server.credentialsOperation = { try await withCheckedThrowingContinuation { pending = $0 } }
        let song = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"new","title":"New"}"#.utf8))
        let old = Task { try await f.downloads.download(song: song, serverId: sid) }
        try await waitUntil { pending != nil }
        let generation = await f.downloads.currentDownloadGeneration()
        let storage = storage(f)
        let clear = Task { await storage.clear(.downloads) }
        try await waitUntil { await f.downloads.currentDownloadGeneration() != generation }
        await #expect(throws: CancellationError.self) { try await f.downloads.download(song: song, serverId: sid) }
        pending?.resume(throwing: URLError(.cancelled))
        _ = await old.result
        await clear.value
        let context = ModelContext(f.model)
        #expect(try context.fetchCount(FetchDescriptor<DownloadedTrack>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DownloadedAlbum>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DownloadedPlaylist>()) == 0)
        #expect(await f.downloads.downloadedSongIds(serverId: sid).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("downloads/old").path))
    }
}

nonisolated private final class IsolationImageProtocol: URLProtocol, @unchecked Sendable {
    private static let count = Mutex(0)
    static var requestCount: Int { count.withLock { $0 } }
    static func reset() { count.withLock { $0 = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count.withLock { $0 += 1 }
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor IsolationTransport: HTTPTransport {
    private var holds = Set<String>()
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var counts: [String: Int] = [:]
    private var paging: Bool?
    func hold(host: String, endpoint: String) { holds.insert(host + ":" + endpoint) }
    func isHeld(host: String, endpoint: String) -> Bool { pending[host + ":" + endpoint] != nil }
    func release(host: String, endpoint: String) { pending.removeValue(forKey: host + ":" + endpoint)?.resume() }
    func count(host: String, endpoint: String) -> Int { counts[host + ":" + endpoint] ?? 0 }
    func setPaging(repeating: Bool) { paging = repeating }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let host = String((url.host ?? "a").prefix(1))
        let endpoint = url.deletingPathExtension().lastPathComponent
        let key = host + ":" + endpoint
        counts[key, default: 0] += 1
        if holds.remove(key) != nil { await withCheckedContinuation { pending[key] = $0 } }
        let offset = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
        var body: [String: Any] = ["status": "ok", "version": "1.16.1"]
        let songs = (0..<5).map { ["id": "\(host)-\($0)", "title": host, "duration": 1] as [String: Any] }
        let album: [String: Any] = ["id": "same", "name": host, "coverArt": "same", "songCount": 5, "duration": 5, "song": songs]
        switch endpoint {
        case "getAlbum": body["album"] = album
        case "getArtist": body["artist"] = ["id": "same", "name": host, "albumCount": 0]
        case "getArtistInfo2": body["artistInfo2"] = ["musicBrainzId": host]
        case "getStarred2": body["starred2"] = ["song": [["id": "same", "title": host]]]
        case "getInternetRadioStations": body["internetRadioStations"] = ["internetRadioStation": [["id": "same", "name": host, "streamUrl": "https://example.invalid/radio"]]]
        case "getAlbumList2":
            if let repeating = paging {
                let ids = repeating || offset == 0 ? ["1", "2"] : (offset == 2 ? ["3", "4"] : [])
                body["albumList2"] = ["album": ids.map { ["id": $0, "name": $0, "songCount": 0, "duration": 0] as [String: Any] }]
            } else { body["albumList2"] = ["album": offset == 0 ? [album] : []] }
        default: break
        }
        return (try JSONSerialization.data(withJSONObject: ["subsonic-response": body]),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
