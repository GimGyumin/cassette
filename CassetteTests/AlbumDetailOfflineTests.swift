// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
import MediaPlayer
import SwiftUI
import SwiftData
@testable import Cassette

// MARK: - Stubs

nonisolated private final class UnexpectedPlaybackRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("A playable original must not wait for a network probe or PlaybackInfo")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

/// Every endpoint throws — AlbumDetailViewModel's offline paths must never
/// reach the server; loadFromAPI's failure is the trigger under test.
@MainActor
private final class ADLibraryStub: LibraryServiceProtocol {
    /// When set, `album(id:)` returns this instead of throwing — used to drive the
    /// empty-but-successful (200, no songs) path that the catch block can't catch.
    func song(id: String) async throws -> Song { throw URLError(.unknown) }
    var albumResult: AlbumID3?
    func album(id: String) async throws -> AlbumID3 {
        if let albumResult { return albumResult }
        throw URLError(.notConnectedToInternet)
    }
    func artists() async throws -> [ArtistIndex] { throw URLError(.unknown) }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    func fetchAllTracks(forArtistID artistID: String) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func playlists() async throws -> [Playlist] { throw URLError(.unknown) }
    func playlist(id: String) async throws -> PlaylistWithSongs { throw URLError(.unknown) }
    func search(_ query: String) async throws -> SearchResult3 { throw URLError(.unknown) }
    func coverArtURL(id: String, size: Int?) async -> URL? { nil }
    func streamURL(songId: String) async -> URL? { nil }
    func star(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func unstar(songIds: [String], albumIds: [String], artistIds: [String]) async throws { throw URLError(.unknown) }
    func getStarred2() async throws -> Starred2 { throw URLError(.unknown) }
    func recentlyAddedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    var allAlbumsCallCount = 0
    var allAlbumsOperation: (() async throws -> [AlbumID3])?
    func allAlbums() async throws -> [AlbumID3] {
        allAlbumsCallCount += 1
        if let allAlbumsOperation { return try await allAlbumsOperation() }
        throw URLError(.unknown)
    }
    func scrobble(songId: String, submission: Bool) async {}
    func recentlyPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func mostPlayedAlbums(size: Int) async throws -> [AlbumID3] { throw URLError(.unknown) }
    func randomSongs(size: Int) async throws -> [Song] { throw URLError(.unknown) }
    func smartShuffleQueue(targetSize: Int) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func similarBackfillQueue(targetSize: Int, excludedIds: Set<String>) async throws -> [DisplayableSong] { throw URLError(.unknown) }
    func savePlayQueue(songIds: [String], currentIndex: Int, positionSeconds: Double) async throws { throw URLError(.unknown) }
    func getPlayQueue() async throws -> SavedPlayQueue? { throw URLError(.unknown) }
    func getArtistInfo(forArtistID artistID: String, count: Int) async throws -> ArtistInfo { throw URLError(.unknown) }
    func getArtistMBID(forArtistID artistID: String) async throws -> String? { nil }
    func findArtist(byName name: String) async -> ArtistID3? { nil }
    func topSongs(artist: String, count: Int) async throws -> [DisplayableSong] { [] }
}

/// Serves a configurable LocalAlbumData; everything else is inert.
@MainActor
private final class ADDownloadStub: DownloadServiceProtocol {
    var albumData: LocalAlbumData?
    var coverURLs: [String: URL] = [:]
    var persistedCovers: [String: Data] = [:]

    let progressStream: AsyncStream<[DownloadProgress]> = AsyncStream { $0.finish() }
    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? { albumData }
    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? { nil }
    func isDownloaded(songId: String, serverId: UUID) async -> Bool { false }
    func downloadedSongIds(serverId: UUID) async -> Set<String> { [] }
    func localCoverArtURL(forId coverArtId: String) async -> URL? { coverURLs[coverArtId] }
    func persistCover(_ data: Data, forId coverArtId: String) async { persistedCovers[coverArtId] = data }
    func removeCover(forId coverArtId: String) async {}
    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int { 0 }
    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? { nil }
    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async {}
    func download(song: Song, serverId: UUID) async throws { throw URLError(.unknown) }
    func download(album: AlbumID3, serverId: UUID) async throws { throw URLError(.unknown) }
    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws { throw URLError(.unknown) }
    func isDownloading(songId: String, serverId: UUID) async -> Bool { false }
    func isDownloadingAlbum(_ albumId: String) async -> Bool { false }
    func isDownloadingPlaylist(_ playlistId: String) async -> Bool { false }
    func cancelDownload(songId: String, serverId: UUID) async {}
    func remove(songId: String, serverId: UUID) async throws { throw URLError(.unknown) }
    func remove(albumId: String, serverId: UUID) async throws { throw URLError(.unknown) }
    func remove(playlistId: String, serverId: UUID) async throws { throw URLError(.unknown) }
}

// MARK: - Tests

@Suite("AlbumDetailViewModel — offline local fallback")
@MainActor
struct AlbumDetailOfflineTests {
    @Test("Uncached Automatic and Lossless request original bytes without negotiation on both networks")
    func uncachedOriginalRouting() async throws {
        let settings = StreamingSettings()
        let oldWiFi = settings.wifiFormat
        let oldCellular = settings.cellularFormat
        defer {
            settings.wifiFormat = oldWiFi
            settings.cellularFormat = oldCellular
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedPlaybackRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let baseURL = try #require(URL(string: "https://music.example.com/proxy"))
        let jellyfinClient = try JellyfinClient(serverBaseURL: baseURL, accessToken: "test-token",
                                               deviceID: "test", session: session)
        let clients = [
            SwiftSonicClient(configuration: ServerConfiguration(serverURL: baseURL, username: "u", password: "p"),
                             transport: StubHTTPTransport(outcome: .urlError(.unsupportedURL)), retryPolicy: .none),
            JellyfinMusicTransport(client: jellyfinClient, user: JellyfinUser(id: "user", name: "User"))
                .makeMusicClient(serverURL: baseURL),
        ]
        let guid = "1234567890abcdef1234567890abcdef"
        let songID = try #require(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: guid))
        let song = DisplayableSong(id: songID, title: "Original", audioFormat: "flac",
                                  bitRate: 1_411, bitDepth: 16, samplingRate: 44_100, channelCount: 2)
        let server = MockServerService()
        server.state.isOnline = true
        server.state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Test", baseURL: baseURL.absoluteString, username: "u"))
        server.credentials = ServerCredentials(password: "p", customHeaders: ["X-Test-Header": "preserved"])
        let jellyfin = JellyfinService(serverService: server, keychain: MockKeychain(),
            modelContainer: try ModelContainer.cassette(inMemory: true),
            deviceIdentity: .init(id: "test", name: "Test", clientName: "Cassette", clientVersion: "1"), session: session)
        let resolver = MediaResolver(downloadService: ADDownloadStub(), cacheService: MockCacheService(),
            serverService: server, serverState: server.state, streamingSettings: settings, jellyfinService: jellyfin)
        for (index, client) in clients.enumerated() {
            server.musicClient = client
            for format in [CacheFormat.matchStream, .flacOriginal] {
                settings.wifiFormat = format
                settings.cellularFormat = format
                for cellular in [false, true] {
                    server.state.isExpensive = cellular
                    let source = try await resolver.resolve(songId: songID, serverId: UUID(), song: song)
                    guard case .stream(let url, let headers, let context, _) = source else {
                        Issue.record("Expected an original network stream")
                        return
                    }
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    if index == 0 {
                        #expect(query.first { $0.name == "format" }?.value == "raw")
                        #expect(!query.contains { $0.name == "maxBitRate" })
                    } else {
                        #expect(url.path == "/proxy/jellyfin/Items/\(guid)/File")
                    }
                    #expect(headers["X-Test-Header"] == "preserved")
                    #expect(context == nil)
                    #expect(!AudioQualityClassifier.isLossyTranscodeStream(source))
                }
            }
            settings.wifiFormat = .aac256
            settings.cellularFormat = .aac256
            let incompleteSong = DisplayableSong(id: songID, title: "Incomplete", audioFormat: "flac")
            let converted = try await resolver.resolve(songId: songID, serverId: UUID(), song: incompleteSong)
            guard case .stream(let url, _, _, _) = converted else {
                Issue.record("Expected a converted network stream")
                return
            }
            if index == 0 {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.first { $0.name == "format" }?.value == "aac")
            } else {
                #expect(url.path == "/proxy/jellyfin/Audio/\(guid)/stream.aac")
                #expect(url.absoluteString.contains("Static=false"))
            }
            #expect(AudioQualityClassifier.isLossyTranscodeStream(converted))
        }
    }

    @Test("Cached audio wins over lossless quality and bitstream streaming, online or offline")
    func cachedAudioHasPriority() async throws {
        let settings = StreamingSettings()
        let oldWiFi = settings.wifiFormat
        let oldCellular = settings.cellularFormat
        defer {
            settings.wifiFormat = oldWiFi
            settings.cellularFormat = oldCellular
        }
        settings.wifiFormat = .flacOriginal
        settings.cellularFormat = .flacOriginal
        let cache = MockCacheService()
        let cachedURL = FileManager.default.temporaryDirectory.appendingPathComponent("cached-track.aac")
        cache.cachedFileURL = cachedURL
        // Network methods throw: a cache hit must never try to construct a streaming client.
        let server = MockServerService()
        let resolver = MediaResolver(downloadService: ADDownloadStub(), cacheService: cache,
                                     serverService: server, serverState: server.state, streamingSettings: settings)
        for online in [true, false] {
            for cellular in [true, false] {
                server.state.isOnline = online
                server.state.isExpensive = cellular
                for format in ["FLAC", "EAC3"] {
                    let track = DisplayableSong(id: "cached", title: "Track", audioFormat: format)
                    let source = try await resolver.resolve(songId: track.id, serverId: UUID(), song: track)
                    guard case .cached(let url) = source else {
                        Issue.record("A cached track must be resolved before streaming quality or routing")
                        return
                    }
                    #expect(url == cachedURL)
                }
            }
        }
    }

    @Test("Album separators retain their width and contrast on light and dark backgrounds")
    func albumSeparatorRendering() throws {
        for width in [240.0, 380.0] {
            for dark in [false, true] {
                let renderer = ImageRenderer(content: AlbumTrackDivider(color: (dark ? Color.white : .black).opacity(0.5))
                    .frame(width: width)
                    .background(dark ? Color.black : .white))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(width * 2))
                #expect(image.height == 2)
                var pixel = [UInt8](repeating: 0, count: 4)
                let sampled = pixel.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return true
                }
                #expect(sampled)
                #expect(pixel[0] > 80 && pixel[0] < 200)
                #expect(pixel[3] == 255)
            }
        }
    }

    @Test("Album track titles wrap at phone widths")
    func albumTitleWrapping() throws {
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: ADLibraryStub())
        let short = DisplayableSong(id: "1", title: "Thriller", artist: "Michael Jackson")
        let long = DisplayableSong(id: "2", title: "Medley: I Want You Back / ABC / The Love You Save (Live from the 1981 U.S. Tour)", artist: "The Jacksons")
        for width in [300.0, 380.0] {
            let shortRenderer = ImageRenderer(content: SongRow(song: short, index: 1, showArtist: false)
                .reservingArtistSpace().frame(width: width).environment(cache))
            let longRenderer = ImageRenderer(content: SongRow(song: long, index: 2)
                .reservingArtistSpace().frame(width: width).environment(cache))
            #if os(iOS)
            let a = try #require(shortRenderer.uiImage)
            let b = try #require(longRenderer.uiImage)
            #elseif os(macOS)
            let a = try #require(shortRenderer.nsImage)
            let b = try #require(longRenderer.nsImage)
            #endif
            #expect(b.size.height > a.size.height)
            #expect(abs(b.size.width - width) < 0.5)
        }
    }

    @Test("Hidden album artists do not leave an empty subtitle row")
    func compactAlbumRows() throws {
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: ADLibraryStub())
        let song = DisplayableSong(id: "1", title: "Thriller", artist: "Michael Jackson")
        let compact = ImageRenderer(content: SongRow(song: song, index: 1, showArtist: false)
            .reservingArtistSpace().frame(width: 320).environment(cache))
        let expanded = ImageRenderer(content: SongRow(song: song, index: 1, showArtist: true)
            .reservingArtistSpace().frame(width: 320).environment(cache))
        #if os(iOS)
        let a = try #require(compact.uiImage)
        let b = try #require(expanded.uiImage)
        #elseif os(macOS)
        let a = try #require(compact.nsImage)
        let b = try #require(expanded.nsImage)
        #endif
        #expect(b.size.height > a.size.height + 10)
        #expect(abs(a.size.width - b.size.width) < 0.5)
    }

    @Test("Repeated metadata updates retain the published Now Playing artwork")
    func repeatedNowPlayingMetadataPreservesArtwork() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        try data.write(to: url)
        let download = ADDownloadStub()
        download.coverURLs["album@hero"] = url
        let cache = ArtworkImageCache(downloadService: download, libraryService: ADLibraryStub())
        let service = NowPlayingService(playerService: MockPlayerService(), artworkImageCache: cache)
        let snapshot = NowPlayingSnapshot(title: "Song", artist: "Artist", album: "Album", duration: 180,
            position: 0, playbackRate: 1, artworkURL: url, artworkHeaders: [:], coverArtId: "album",
            isLiveStream: false, radioStationName: nil, isrc: nil)
        await service.update(with: snapshot)
        let first = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        await service.update(with: snapshot)
        let second = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        #expect(first === second)
        await service.publishTrackChange(snapshot)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil)
        await service.stop()
    }

    @Test("Cover preload excludes absent artwork and deduplicates cover IDs")
    func coverDownloadTargets() {
        let albums = [
            AlbumID3(id: "1", name: "No cover", songCount: 1, duration: 1),
            AlbumID3(id: "2", name: "Empty cover", songCount: 1, duration: 1, coverArt: " "),
            AlbumID3(id: "3", name: "Cover", songCount: 1, duration: 1, coverArt: "cover"),
            AlbumID3(id: "4", name: "Shared cover", songCount: 1, duration: 1, coverArt: "cover")
        ]
        #expect(AlbumCoverPreloadService.coverIDs(for: albums) == ["cover"])
        #expect(AlbumCoverPreloadService.coverIDs(for: []) == [])
        #expect(AlbumCoverPreloadService.coverIDs(for: albums,
            songCoverIDs: ["song-cover-1", "song-cover-2", "cover", "song-cover-1"]) == ["cover", "song-cover-1", "song-cover-2"])
    }

    @Test("Album downloads fetch the shared cover once and only distinct track covers additionally")
    func albumDownloadCoverTargets() {
        #expect(DownloadService.albumCoverArtIDs(
            albumCoverArtID: "album-cover",
            songCoverArtIDs: ["album-cover", "track-cover", "album-cover", "track-cover", nil, " "]
        ) == ["album-cover", "track-cover"])
        #expect(DownloadService.albumCoverArtIDs(
            albumCoverArtID: nil,
            songCoverArtIDs: ["first", "first", "second"]
        ) == ["first", "second"])
    }

    @Test("Album rows reserve subtitle space independently of artist visibility")
    func albumRowSpacing() {
        let song = DisplayableSong(id: "1", title: "Song")
        let row = SongRow(song: song, index: 1, showArtist: false).reservingArtistSpace()
        #expect(row.reservesArtistSpace)
        #expect(!row.showArtist)
        #expect(!SongRow(song: song, index: 1).reservesArtistSpace)
    }

    @Test("Album rows show performers different from the album artist")
    func albumArtistVisibility() {
        let solo = DisplayableSong(id: "1", title: "Song", artist: "Michael Jackson", displayComposer: "Another Writer")
        #expect(!solo.showsArtist(inAlbumBy: " michael jackson "))
        #expect(DisplayableSong(id: "2", title: "Song", artist: "Jackson 5").showsArtist(inAlbumBy: "Michael Jackson"))
        #expect(!DisplayableSong(id: "3", title: "Song").showsArtist(inAlbumBy: "Michael Jackson"))
        #expect(solo.showsArtist(inAlbumBy: nil))
    }

    @Test("Downloaded hero covers supply offline album thumbnails")
    func heroSuppliesOfflineThumbnail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        try data.write(to: url)
        let download = ADDownloadStub()
        download.coverURLs["album@hero"] = url
        let cache = ArtworkImageCache(downloadService: download, libraryService: ADLibraryStub())
        #expect(await cache.load(coverArtId: "album", tier: .thumb, allowNetwork: false) != nil)
        #expect(download.persistedCovers["album@thumb"] != nil)
    }

    @Test("Cover preparation builds a page palette from disk without a RAM image")
    func preloadPreparesDiskOnlyPalette() async throws {
        let id = "preload-test-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        try data.write(to: url)
        let download = ADDownloadStub()
        download.coverURLs["\(id)@hero"] = url
        let cache = ArtworkImageCache(downloadService: download, libraryService: ADLibraryStub())
        #expect(cache.cachedImage(for: id, tier: .hero) == nil)
        #expect(ColorCache.palette(for: id) == nil)
        #expect(await AlbumCoverPreloadService.prepareTheme(
            for: id, artworkImageCache: cache, dominantColorExtractor: nil
        ))
        #expect(ColorCache.palette(for: id) != nil)
    }

    @Test("Prepared backgrounds survive a fresh extractor without loading artwork")
    func preparedBackgroundPersistsPerCover() {
        let first = "prepared-first-\(UUID().uuidString)"
        let second = "prepared-second-\(UUID().uuidString)"
        let extractor = DominantColorExtractor()
        defer {
            extractor.invalidate(for: first)
            extractor.invalidate(for: second)
            extractor.persistPreparedBackgrounds()
        }
        _ = extractor.storeColor(packed: 0x000000, for: first)
        extractor.storePreparedBackground(0x89ABCD, for: first)
        extractor.storePreparedBackground(0x123456, for: second)
        extractor.persistPreparedBackgrounds()

        let restored = DominantColorExtractor()
        #expect(restored.cachedColors()[first] == 0x89ABCD)
        #expect(restored.cachedColors()[second] == 0x123456)
        #expect(restored.cachedColor(for: first) != nil)
    }

    @Test("Missing artwork cannot count as a prepared page theme")
    func preloadRejectsMissingPalette() async {
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: ADLibraryStub())
        #expect(await AlbumCoverPreloadService.prepareTheme(
            for: UUID().uuidString, artworkImageCache: cache, dominantColorExtractor: nil
        ) == false)
    }

    @Test("Leaving preparation keeps the service-owned download alive and joins it")
    func deferCoverPreparation() async {
        let library = ADLibraryStub()
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: library)
        let preload = AlbumCoverPreloadService(libraryService: library, artworkImageCache: cache)
        var scheduled = 0
        preload.requestBackgroundContinuation = { scheduled += 1 }
        var pendingAlbums: CheckedContinuation<[AlbumID3], Never>?
        library.allAlbumsOperation = { await withCheckedContinuation { pendingAlbums = $0 } }
        let screen = Task { await preload.downloadAllCovers() }
        while pendingAlbums == nil { await Task.yield() }
        preload.deferRemainingDownloads()
        screen.cancel()
        await screen.value
        #expect(preload.isDeferred)
        #expect(preload.state.isDownloading)
        #expect(library.allAlbumsCallCount == 1)
        #expect(scheduled >= 1)
        var backgroundJoined = false
        let background = Task {
            backgroundJoined = true
            await preload.downloadAllCovers(resumeDeferred: false)
        }
        while !backgroundJoined { await Task.yield() }
        pendingAlbums?.resume(returning: [])
        await background.value
        #expect(preload.state.isComplete)
        #expect(!preload.state.isDownloading)
        #expect(preload.state.errorMessage == nil)
        #expect(library.allAlbumsCallCount == 1)

        let preparation = LibraryPreparationService()
        preparation.deferPresentation()
        preparation.receiveExternalProgress(.init(phase: .covers, coversCompleted: 1, coversTotal: 3))
        #expect(preparation.phase == .covers)
        #expect(preparation.isPresentationDeferred)
        preparation.reset()
        #expect(preparation.isPresentationDeferred)
    }

    @Test("Background download policy uses a rolling window without per-file sleeps")
    func backgroundPreparationPolicy() {
        var budget = PerformanceBudget.placeholder
        #expect(PreparationDownloadPolicy.concurrency(budget: budget, isLimited: false, isPlaying: false) == 4)
        budget = .make(thermalPressure: .nominal, isLowPowerMode: false, isAppActive: false, reduceMotion: false)
        #expect(PreparationDownloadPolicy.concurrency(budget: budget, isLimited: false, isPlaying: false) == 4)
        #expect(PreparationDownloadPolicy.concurrency(budget: budget, isLimited: true, isPlaying: true) == 1)
        budget = .make(thermalPressure: .serious, isLowPowerMode: false, isAppActive: true, reduceMotion: false)
        #expect(PreparationDownloadPolicy.concurrency(budget: budget, isLimited: false, isPlaying: false) == 1)
    }

    @Test("Background artwork persistence rejects error pages and accepts image files")
    func backgroundArtworkValidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html>Service unavailable</html>".utf8).write(to: url)
        #expect(!CassetteBackgroundDownloads.isValidArtwork(at: url))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        try png.write(to: url)
        #expect(CassetteBackgroundDownloads.isValidArtwork(at: url))
    }

    @Test("Resuming preparation reuses originals saved by background transfers")
    func preparationReusesPersistedOriginals() async throws {
        let album = try await emptySuccessAlbum()
        let coverID = try #require(album.coverArt)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        try png.write(to: directory.appendingPathComponent(OriginalArtwork.storageID(coverID)))
        let library = ADLibraryStub()
        library.allAlbumsOperation = { [album] }
        // This cache cannot fetch artwork; success must come from the persisted original.
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: library)
        let preload = AlbumCoverPreloadService(libraryService: library, artworkImageCache: cache, coversDirectory: directory)
        await preload.downloadAllCovers()
        #expect(preload.state.isComplete)
        #expect(preload.state.alreadyPrepared == 1)
        #expect(preload.state.total == 0)
        #expect(preload.state.failed == 0)
    }

    @Test("Cover preload exposes library errors and permits retry")
    func coverPreloadFailure() async {
        let library = ADLibraryStub()
        let cache = ArtworkImageCache(downloadService: ADDownloadStub(), libraryService: library)
        let preload = AlbumCoverPreloadService(libraryService: library, artworkImageCache: cache)
        await preload.downloadAllCovers()
        #expect(preload.state.errorMessage != nil)
        #expect(!preload.state.isDownloading)
        #expect(!preload.state.isComplete)
        await preload.downloadAllCovers()
        #expect(preload.state.errorMessage != nil)
        #expect(!preload.state.isDownloading)
    }

    private func song(_ id: String) -> DisplayableSong {
        DisplayableSong(
            id: id, title: "Track \(id)", artist: "Artist", albumId: "album-1",
            albumName: "Album", artistId: nil, genre: nil, duration: 180,
            trackNumber: nil, isDownloaded: true, coverArtId: nil, audioFormat: nil,
            replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
    }

    private func makeVM(albumData: LocalAlbumData?, isOnline: Bool, apiAlbum: AlbumID3? = nil) -> AlbumDetailViewModel {
        let state = ServerState()
        state.isOnline = isOnline
        state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "S", baseURL: "https://s.example.com", username: "u", isActive: true
        ))
        let download = ADDownloadStub()
        download.albumData = albumData
        let library = ADLibraryStub()
        library.albumResult = apiAlbum
        return AlbumDetailViewModel(
            albumId: "album-1",
            libraryService: library,
            downloadService: download,
            toastService: ToastService(),
            serverState: state
        )
    }

    /// Builds a genuine, empty `AlbumID3` (200 OK, no songs) through SwiftSonic's real
    /// decoder driven by the canned-response transport — the WARP/Cloudflare edge case.
    private func emptySuccessAlbum() async throws -> AlbumID3 {
        let json = Data(#"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"album-1","name":"Album","artist":"Artist","artistId":"ar-1","songCount":0,"duration":0,"created":"2024-01-01T00:00:00.000Z","coverArt":"al-1","song":[]}}}
        """#.utf8)
        let client = SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: URL(string: "https://stub.example.com")!, username: "u", password: "p"
            ),
            transport: StubHTTPTransport(outcome: .response(data: json, statusCode: 200)),
            retryPolicy: .none
        )
        return try await client.getAlbum(id: "album-1")
    }

    private var downloadedAlbum: LocalAlbumData {
        LocalAlbumData(
            albumId: "album-1", albumName: "Album", artistName: "Artist",
            coverArtId: nil, songs: [song("1"), song("2")]
        )
    }

    @Test("downloaded album falls back to local when the server call fails (stale isOnline)")
    func downloadedAlbumFallsBackOnServerFailure() async {
        let vm = makeVM(albumData: downloadedAlbum, isOnline: true)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(vm.albumName == "Album")
        #expect(vm.isPrimaryContentReady)
    }

    @Test("transient failure with no local copy shows the error, not a false offline state")
    func transientFailureWithoutLocalCopyShowsError() async {
        let vm = makeVM(albumData: nil, isOnline: true)
        await vm.load()
        #expect(vm.error != nil)
        #expect(vm.isOffline == false)
        #expect(vm.songs.isEmpty)
        #expect(!vm.isPrimaryContentReady)
    }

    @Test("genuinely offline, downloaded album loads from local with no server call")
    func offlineDownloadedAlbumLoadsLocally() async {
        let vm = makeVM(albumData: downloadedAlbum, isOnline: false)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(vm.isPrimaryContentReady)
    }

    @Test("genuinely offline, non-downloaded album shows the empty state — no error")
    func offlineNonDownloadedShowsEmptyState() async {
        let vm = makeVM(albumData: nil, isOnline: false)
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(!vm.isPrimaryContentReady)
    }

    // MARK: - Empty-success (WARP / Cloudflare edge) — the case the throw-only stubs missed

    @Test("empty-success album response with a downloaded copy loads local, not empty")
    func emptySuccessAlbumFallsBackToLocal() async throws {
        let empty = try await emptySuccessAlbum()
        let vm = makeVM(albumData: downloadedAlbum, isOnline: true, apiAlbum: empty)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.error == nil)
        #expect(vm.isOffline == true)
        #expect(vm.isPrimaryContentReady)
    }

    @Test("empty-success album with NO downloaded copy stays empty, no error")
    func emptySuccessAlbumNoLocalStaysEmpty() async throws {
        let empty = try await emptySuccessAlbum()
        let vm = makeVM(albumData: nil, isOnline: true, apiAlbum: empty)
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isPrimaryContentReady)
    }
}
