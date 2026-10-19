import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Logical Atmos albums and playback identities", .serialized)
@MainActor
struct AtmosVariantTests {
    private func song(_ id: String, title: String = "Billie Jean", album: String = "Thriller",
                      albumID: String = "stereo", artist: String = "Michael Jackson", duration: Double = 294,
                      mbid: String? = nil) -> DisplayableSong {
        DisplayableSong(id: id, title: title, artist: artist, albumId: albumID, albumName: album,
                        artistId: artist, duration: duration, trackNumber: 1, coverArtId: "cover-" + albumID,
                        audioFormat: "M4A", contentType: "audio/mp4", channelCount: 2,
                        musicBrainzRecordingID: mbid)
    }
    private func album(_ id: String, name: String, artist: String = "Michael Jackson", songs: [DisplayableSong] = []) -> AlbumID3 {
        AlbumID3(id: id, name: name, songCount: songs.count, duration: 294, artist: artist,
                 artistId: artist, coverArt: "cover-" + id, song: songs.map { $0.asSong() })
    }

    @Test func pairsOnlyExactSuffixSameArtistAndUniqueBase() {
        let base = album("s", name: "Dangerous")
        let atmos = album("a", name: "Dangerous (dOlBy AtMoS)  ")
        let foreign = album("other", name: "Dangerous (Dolby Atmos)", artist: "Other Artist")
        let only = album("only", name: "HIStory (Dolby Atmos)")
        let remaster = album("remaster", name: "Dangerous (Remastered)")
        #expect(AtmosAlbumPolicy.presented([atmos, base, foreign, only, remaster]).map(\.id) == ["s", "other", "only", "remaster"])
        #expect(AtmosAlbumPolicy.presented([atmos]).map(\.id) == ["a"])
        #expect(AtmosAlbumPolicy.presented([atmos], catalog: [base]).first?.id == "s")
        #expect(AtmosAlbumPolicy.presented([base, album("s2", name: "Dangerous"), atmos]).count == 3)
        #expect(AtmosAlbumPolicy.baseName("Dangerous (Dolby Atmos) Bonus") == "Dangerous (Dolby Atmos) Bonus")
    }

    @Test func prefersSameAlbumBeforeRecordingIDOnACompilation() {
        let original = song("s", mbid: "recording")
        let paired = song("a", album: "Thriller (Dolby Atmos)", albumID: "atmos")
        let compilation = song("c", album: "The Essential (Dolby Atmos)", albumID: "comp", mbid: "recording")
        let catalog = AtmosVariantCatalogue(songs: [original, paired, compilation], albums: [
            album("stereo", name: "Thriller"), album("atmos", name: "Thriller (Dolby Atmos)")
        ])
        #expect(catalog.preferred(for: original)?.id == "a")
    }

    @Test func compilationMatchingUsesRecordingIdentityAndRejectsAmbiguity() {
        let original = song("s", mbid: "r")
        let exact = song("a", album: "The Essential (Dolby Atmos)", mbid: "r")
        let unknown = song("b", album: "HIStory (Dolby Atmos)")
        #expect(AtmosVariantCatalogue(songs: [original, exact, unknown]).preferred(for: original)?.id == "a")
        let originalWithoutID = song("s")
        #expect(AtmosVariantCatalogue(songs: [originalWithoutID, exact, unknown]).preferred(for: originalWithoutID) == nil)
        #expect(AtmosVariantCatalogue(songs: [original, song("bad", album: "The Essential (Dolby Atmos)", mbid: "different")]).preferred(for: original) == nil)
    }

    @Test(arguments: [0.0, 1.0, 2.0, -2.0])
    func acceptsOnlySmallKnownDurationDifferences(_ delta: Double) {
        let original = song("s")
        let candidate = song("a", album: "The Essential (Dolby Atmos)", duration: 294 + delta)
        #expect(AtmosVariantCatalogue.compatible(original, candidate))
    }

    @Test(arguments: [0.0, 297.0, Double.infinity, Double.nan])
    func rejectsMissingInvalidOrLongDuration(_ duration: Double) {
        #expect(!AtmosVariantCatalogue.compatible(song("s"), song("a", album: "The Essential (Dolby Atmos)", duration: duration)))
    }

    @Test(arguments: ["Billie Jean (Live)", "Billie Jean (Radio Edit)", "Billie Jean (Remix)", "Billie Jean (Instrumental)", "Billie Jean - Single Version"])
    func neverStripsRecordingVersions(_ title: String) {
        #expect(!AtmosVariantCatalogue.compatible(song("s"), song("a", title: title, album: "The Essential (Dolby Atmos)")))
    }

    @Test func rejectsDifferentArtistAndAlbumLiveContext() {
        #expect(!AtmosVariantCatalogue.compatible(song("s"), song("a", album: "The Essential (Dolby Atmos)", artist: "Other Artist")))
        #expect(!AtmosVariantCatalogue.compatible(song("s", album: "Live at Wembley"), song("a", album: "The Essential (Dolby Atmos)")))
        #expect(!AtmosVariantCatalogue.compatible(song("s"), song("a", album: "The Remixes (Dolby Atmos)")))
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let model: ModelContainer
        let server: MockServerService
        let downloads: DownloadService
        let index: LibraryIndexService
        let settings: StreamingSettings
        let resolver: MediaResolver
        let sid: UUID
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        let suite = "Cassette.AtmosTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Test", baseURL: "https://music.example.invalid", username: "u"))
        let sid = try #require(server.state.activeServer?.id)
        server.credentials = ServerCredentials(password: "p", customHeaders: ["X-Test": "original-pair"])
        server.musicClient = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://music.example.invalid")!, username: "u", password: "p"),
            transport: StubHTTPTransport(outcome: .urlError(.unsupportedURL)), retryPolicy: .none)
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        let index = LibraryIndexService(serverID: { server.state.activeServer?.id }, networkAvailable: { false }, directory: root, defaults: defaults)
        let original = song("s"), alternate = song("a", album: "Thriller (Dolby Atmos)", albumID: "atmos")
        let albums = [album("stereo", name: "Thriller", songs: [original]), album("atmos", name: "Thriller (Dolby Atmos)", songs: [alternate])]
        let snapshot = LibraryIndexService.Snapshot(artists: [], albums: albums.map {
            .init(id: $0.id, name: $0.name, artist: $0.artist, coverArtId: $0.coverArt)
        }, playlists: [], songs: [original, alternate], date: Date(), albumCatalog: albums)
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("\(sid).json"))
        #expect(await index.ensureIndexedAndWait(using: SearchLibraryStub()))
        let settings = StreamingSettings(defaults: defaults)
        let resolver = MediaResolver(downloadService: downloads, cacheService: MockCacheService(), serverService: server,
            serverState: server.state, streamingSettings: settings, libraryIndex: index)
        return Fixture(root: root, defaults: defaults, suite: suite, model: model, server: server,
                       downloads: downloads, index: index, settings: settings, resolver: resolver, sid: sid)
    }

    @Test func persistedIndexMergesSearchAndRestoresAccountScopedManualChoice() async throws {
        let f = try await fixture(); defer { f.clean() }
        #expect(f.index.search(query: "Thriller").albums.map(\.id) == ["stereo"])
        #expect(f.index.preferredAtmosSong(for: song("s"), serverId: f.sid)?.id == "a")
        f.index.setManualAtmosSelection("", for: song("s"), serverId: f.sid)
        #expect(f.index.preferredAtmosSong(for: song("s"), serverId: f.sid) == nil)
        let restored = LibraryIndexService(serverID: { f.server.state.activeServer?.id }, networkAvailable: { false }, directory: f.root, defaults: f.defaults)
        #expect(await restored.ensureIndexedAndWait(using: SearchLibraryStub()))
        #expect(restored.manualAtmosSelection(songId: "s", serverId: f.sid) == "")
        restored.setManualAtmosSelection("a", for: song("s"), serverId: f.sid)
        #expect(restored.preferredAtmosSong(for: song("s"), serverId: f.sid)?.id == "a")
        f.server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.invalid", username: "u"))
        #expect(restored.preferredAtmosSong(for: song("s"), serverId: f.sid) == nil)
        restored.clearAtmosSelections(serverId: f.sid)
        #expect(f.defaults.dictionary(forKey: "cassette.atmos.matches.\(f.sid)") == nil)
    }

    @Test func preferenceUsesActualTrackRawStreamWithoutChangingDisplayIdentity() async throws {
        let f = try await fixture(); defer { f.clean() }
        #expect(!f.settings.preferDolbyAtmos)
        f.settings.wifiFormat = .aac128
        f.settings.preferDolbyAtmos = true
        let original = song("s")
        let source = try await f.resolver.resolve(songId: original.id, serverId: f.sid, song: original)
        #expect(source.playbackSong?.id == "a")
        #expect(source.customHeaders["X-Test"] == "original-pair")
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "id" }?.value == "a")
        #expect(query.first { $0.name == "format" }?.value == "raw")
        #expect(!query.contains { $0.name == "maxBitRate" })
        #expect(original.id == "s" && original.coverArtId == "cover-stereo")
        #expect(AudioQualityClassifier.requiresSystemPlayer(try #require(source.playbackSong)))
        #expect(StreamingSettings(defaults: f.defaults).preferDolbyAtmos)
        f.settings.preferDolbyAtmos = false
        let stereo = try await f.resolver.resolve(songId: "s", serverId: f.sid, song: original)
        #expect(stereo.playbackSong == nil)
        #expect(URLComponents(url: stereo.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value == "s")
    }

    @Test func offlineUsesOriginalDownloadAndRejectsConvertedAtmosFile() async throws {
        let f = try await fixture(); defer { f.clean() }
        let context = ModelContext(f.model)
        for id in ["s", "a"] {
            try Data([1, 2, 3]).write(to: f.root.appendingPathComponent("downloads/\(id).m4a"))
            context.insert(DownloadedTrack(songId: id, serverId: f.sid, filePath: "\(id).m4a", fileSize: 3,
                mimeType: "audio/mp4", isOriginalAudio: id == "s", title: "Billie Jean", artist: "Michael Jackson",
                album: id == "a" ? "Thriller (Dolby Atmos)" : "Thriller", suffix: "m4a"))
        }
        try context.save()
        f.server.state.isOnline = false
        f.settings.preferDolbyAtmos = true
        let fallback = try await f.resolver.resolve(songId: "s", serverId: f.sid, song: song("s"))
        #expect(fallback.url.lastPathComponent == "s.m4a")
        #expect(fallback.playbackSong == nil)
        let rows = try context.fetch(FetchDescriptor<DownloadedTrack>())
        let atmosRow = try #require(rows.first { $0.songId == "a" })
        atmosRow.isOriginalAudio = true
        try context.save()
        let spatial = try await f.resolver.resolve(songId: "s", serverId: f.sid, song: song("s"))
        #expect(spatial.url.lastPathComponent == "a.m4a")
        #expect(spatial.playbackSong?.id == "a")
        try FileManager.default.removeItem(at: spatial.url)
        let missing = try await f.resolver.resolve(songId: "s", serverId: f.sid, song: song("s"))
        #expect(missing.url.lastPathComponent == "s.m4a")
    }

    @Test func logicalOfflineAlbumPreservesExtraTracksAndSharedFilesOnRemoval() async throws {
        let f = try await fixture(); defer { f.clean() }
        let context = ModelContext(f.model)
        for (id, albumID) in [("s", "stereo"), ("extra", "atmos")] {
            try Data([1]).write(to: f.root.appendingPathComponent("downloads/\(id).m4a"))
            context.insert(DownloadedTrack(songId: id, serverId: f.sid, albumId: albumID,
                filePath: "\(id).m4a", fileSize: 1, mimeType: "audio/mp4", title: id))
        }
        context.insert(DownloadedAlbum(albumId: "stereo", serverId: f.sid, name: "Thriller", tracksCount: 2,
            totalTracksCount: 2, songIds: ["s", "extra"]))
        context.insert(DownloadedPlaylist(playlistId: "shared", serverId: f.sid, name: "Shared",
            tracksCount: 1, totalTracksCount: 1, songIds: ["extra"]))
        try context.save()
        let local = await f.downloads.localAlbumData(albumId: "stereo", serverId: f.sid)
        #expect(local?.songs.map(\.id) == ["s", "extra"])
        _ = await f.downloads.downloadedSongIds(serverId: f.sid)
        #expect(try ModelContext(f.model).fetch(FetchDescriptor<DownloadedAlbum>()).first?.tracksCount == 2)
        try await f.downloads.remove(songId: "s", serverId: f.sid)
        #expect(try ModelContext(f.model).fetch(FetchDescriptor<DownloadedAlbum>()).first?.tracksCount == 1)
        #expect(await f.downloads.localAlbumData(albumId: "stereo", serverId: f.sid)?.songs.map(\.id) == ["extra"])
        try await f.downloads.remove(albumId: "stereo", serverId: f.sid)
        #expect(await f.downloads.downloadedURL(forSongId: "s", serverId: f.sid) == nil)
        #expect(await f.downloads.downloadedURL(forSongId: "extra", serverId: f.sid) != nil)
    }

    @Test func backwardCompatibleSongDecodeAndMetadataRoundTrip() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(song("s", mbid: "r"))) as? [String: Any])
        payload.removeValue(forKey: "musicBrainzRecordingID")
        payload.removeValue(forKey: "isOriginalAudio")
        let restored = try JSONDecoder().decode(DisplayableSong.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(restored.id == "s" && restored.musicBrainzRecordingID == nil)
        #expect(DisplayableSong(from: song("s", mbid: "r").asSong()).musicBrainzRecordingID == "r")
    }

    @Test func detailCombinesUnequalAlbumsAndWarmsImmediatePlaybackWithoutFullIndex() async throws {
        let f = try await fixture(); defer { f.clean() }
        f.index.clear()
        let original = song("s"), stereoOnly = song("only", title: "Stereo Only")
        let alternate = song("a", album: "Thriller (Dolby Atmos)", albumID: "atmos")
        let extra = song("extra", title: "Bonus", album: "Thriller (Dolby Atmos)", albumID: "atmos")
        let base = album("stereo", name: "Thriller", songs: [original, stereoOnly])
        let spatial = album("atmos", name: "Thriller (Dolby Atmos)", songs: [alternate, extra])
        func response<T: Encodable>(_ value: T, key: String) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            return try JSONSerialization.data(withJSONObject: ["subsonic-response": ["status": "ok", "version": "1.16.1", key: object]])
        }
        let artist = ArtistID3(id: "Michael Jackson", name: "Michael Jackson", album: [base, spatial])
        f.server.musicClient = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://music.example.invalid")!, username: "u", password: "p"),
            transport: AtmosAlbumTransport(responses: ["stereo": try response(base, key: "album"), "atmos": try response(spatial, key: "album"), "artist": try response(artist, key: "artist")]), retryPolicy: .none)
        let library = LibraryService(serverService: f.server, modelContainer: f.model, downloadService: f.downloads,
                                     statsService: StatsService(modelContainer: f.model), libraryIndex: f.index)
        let detail = try await library.displayAlbum(id: "atmos")
        #expect(detail.id == "stereo" && detail.name == "Thriller" && detail.coverArt == "cover-stereo")
        #expect(detail.song?.map(\.id) == ["s", "only", "extra"])
        #expect(detail.song?.last?.albumId == "atmos")
        #expect(detail.duration == base.duration + Int(extra.duration))
        #expect(try await library.album(id: "stereo").song?.map(\.id) == ["s", "only"])
        #expect(!f.index.hasUsableIndex)
        #expect(f.index.preferredAtmosSong(for: original, serverId: f.sid)?.id == "a")
        #expect(f.index.preferredAtmosSong(for: stereoOnly, serverId: f.sid) == nil)
    }

    @Test func playerKeepsVisibleAlbumAndQueueWhilePublishingActualAudioMetadata() async throws {
        let f = try await fixture(); defer { f.clean() }
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let original = song("s")
        let alternate = song("a", album: "Thriller (Dolby Atmos)", albumID: "atmos")
        let player = PlayerService(state: container.playerState, mediaResolver: f.resolver, serverService: f.server,
            sessionService: container.sessionService, artworkImageCache: container.artworkImageCache,
            lyricsService: container.lyricsService, libraryService: SearchLibraryStub(), cacheService: MockCacheService(),
            downloadService: f.downloads, cacheSettings: container.cacheSettings, streamingSettings: f.settings,
            replayGainSettings: container.replayGainSettings, crossfadeSettings: container.crossfadeSettings,
            gaplessSettings: container.gaplessSettings, toastService: container.toastService, statsService: container.statsService,
            listenBrainzService: container.listenBrainzService, engine: engine)
        container.playerState.queue = [original]
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SilentMP3.mp3")
        await player.startPlayback(song: original, source: .downloaded(file, playbackSong: alternate),
                                   serverId: f.sid, epoch: 0, preservePlayingState: false)
        #expect(container.playerState.currentTrack?.id == "s")
        #expect(container.playerState.currentTrack?.coverArtId == "cover-stereo")
        #expect(container.playerState.queue.map(\.id) == ["s"])
        #expect(container.playerState.currentPlaybackTrack?.id == "a")
        await player.stop()
        #expect(container.playerState.currentPlaybackTrack == nil)
    }
}

nonisolated private struct AtmosAlbumTransport: HTTPTransport, Sendable {
    let responses: [String: Data]
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let isArtist = url.lastPathComponent.hasPrefix("getArtist")
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        guard let data = responses[isArtist ? "artist" : id] else { throw URLError(.unsupportedURL) }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
