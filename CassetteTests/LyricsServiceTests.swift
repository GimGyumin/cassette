// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Cassette

// MARK: - Minimal mock for LyricsService construction

@MainActor
final class MockLyricsServerService: ServerServiceProtocol {
    let state: ServerState = ServerState()
    var lyricsClient: SwiftSonicClient?
    func addServer(displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func addServerWithJellyfinToken(displayName: String, baseURL: String, username: String, jellyfinAccessToken: String, customHeaders: [String: String]) async throws {}
    func removeServer(id: UUID) async throws {}
    func setActiveServer(id: UUID) async throws {}
    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {}
    func updateServer(id: UUID, displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func testConnection() async throws {}
    func testConnection(url: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func makeSwiftSonicClient() async throws -> SwiftSonicClient {
        guard let lyricsClient else { throw CassetteError.notImplemented }
        return lyricsClient
    }
    func activeCredentials() async throws -> ServerCredentials { throw CassetteError.notImplemented }
    func loadPersistedState() async {}
    func preWarmClient() async {}
}

// MARK: - Helpers

@MainActor
private func makeService() throws -> (LyricsService, ModelContainer) {
    let container = try ModelContainer(
        for: Schema([CachedLyrics.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let mock = MockLyricsServerService()
    let service = LyricsService(serverService: mock, modelContainer: container)
    return (service, container)
}

private func sampleList() -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)]),
        StructuredLyrics(lang: "fr", synced: false, line: [Line(value: "Bonjour")])
    ])
}

// MARK: - selectBestLanguage

@Suite("LyricsService — selectBestLanguage")
@MainActor
struct LyricsSelectBestLanguageTests {

    @Test func emptyList_returnsNil() {
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: LyricsList(structuredLyrics: []))
        #expect(result == nil)
    }

    @Test func preferred_syncedVariantChosen() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "fr", synced: false, line: []),
            StructuredLyrics(lang: "fr", synced: true, line: [])
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: list, preferred: "fr")
        #expect(result?.synced == true)
    }

    @Test func preferred_unsyncedFallback_whenNoSynced() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "fr", synced: false, line: [])
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: list, preferred: "fr")
        #expect(result?.lang == "fr")
        #expect(result?.synced == false)
    }

    @Test func locale_frFR_picksFrenchUnsynced_overEnglishSynced() {
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: sampleList(), locale: Locale(identifier: "fr_FR"))
        #expect(result?.lang == "fr")
    }

    @Test func locale_enUS_picksSyncedEnglish() {
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: sampleList(), locale: Locale(identifier: "en_US"))
        #expect(result?.lang == "en")
        #expect(result?.synced == true)
    }

    @Test func noLocaleMatch_returnFirstSynced() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "ja", synced: false, line: []),
            StructuredLyrics(lang: "ko", synced: true, line: [])
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: list, locale: Locale(identifier: "fr_FR"))
        #expect(result?.lang == "ko")
        #expect(result?.synced == true)
    }

    @Test func xxx_normalizedToUnd() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "xxx", synced: true, line: [])
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: list, preferred: "und")
        #expect(result?.synced == true)
    }

    @Test func karaoke_preferredOverLocaleLanguage() {
        let cue = LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 4)
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [Line(value: "Hello", start: 0)],
                cueLine: [CueLine(index: 0, value: "Hello", cue: [cue])]
            ),
            StructuredLyrics(lang: "fr", synced: true, line: [Line(value: "Bonjour", start: 0)]),
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(from: list, locale: Locale(identifier: "fr_FR"))
        #expect(result?.lang == "en")
        #expect(result?.hasKaraokeCues == true)
    }

    @Test func karaoke_beatsPreferredLanguage() {
        let cue = LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 4)
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [Line(value: "Hello", start: 0)],
                cueLine: [CueLine(index: 0, value: "Hello", cue: [cue])]
            ),
            StructuredLyrics(lang: "fr", synced: true, line: [Line(value: "Bonjour", start: 0)]),
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(
            from: list,
            locale: Locale(identifier: "en_US"),
            preferred: "fr"
        )
        #expect(result?.lang == "en")
        #expect(result?.hasKaraokeCues == true)
    }

    @Test func preferredLanguage_winsWhenNoKaraokeAvailable() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)]),
            StructuredLyrics(lang: "fr", synced: true, line: [Line(value: "Bonjour", start: 0)]),
        ])
        let (service, _) = try! makeService()
        let result = service.selectBestLanguage(
            from: list,
            locale: Locale(identifier: "en_US"),
            preferred: "fr"
        )
        #expect(result?.lang == "fr")
    }
}

// MARK: - Cache hit

@Suite("LyricsService — cache")
@MainActor
struct LyricsCacheTests {

    @Test func cacheHit_returnsWithoutNetwork() async throws {
        let (service, container) = try makeService()
        let serverId = UUID()
        let songId = "song-xyz"
        let cue = LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 4)
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [Line(value: "Hello", start: 0)],
                cueLine: [CueLine(index: 0, value: "Hello", cue: [cue])]
            )
        ])

        // Pre-populate cache directly via ModelContext
        let data = try JSONEncoder().encode(list)
        await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(CachedLyrics(songId: songId, serverId: serverId, jsonPayload: data))
            try? ctx.save()
        }

        // Karaoke cache hits without touching the network (mock throws on client creation).
        let result = try await service.fetchLyrics(forSongId: songId, serverId: serverId)
        #expect(result == list)
    }

    @Test func legacyLRCCache_fallsBackWhenUpgradeUnavailable() async throws {
        let (service, container) = try makeService()
        let serverId = UUID()
        let songId = "song-lrc"
        let list = sampleList()

        let data = try JSONEncoder().encode(list)
        await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(CachedLyrics(songId: songId, serverId: serverId, jsonPayload: data))
            try? ctx.save()
        }

        // Mock cannot create a client → karaoke upgrade probe fails → keep synced LRC.
        let result = try await service.fetchLyrics(forSongId: songId, serverId: serverId)
        #expect(result == list)
    }
}

// MARK: - Library lyrics generation

private struct StubExternalLyricsProvider: ExternalLyricsProviding {
    func fetchLyrics(match: LyricsMatchInfo) async throws -> LyricsList {
        throw LyricsError.notFound
    }
}

@MainActor
private final class LyricsGenLibraryStub: LibraryServiceProtocol {
    var songPages: [Int: [Song]] = [:]

    func librarySongs(offset: Int, count: Int) async throws -> [Song] {
        songPages[offset] ?? []
    }

    func song(id: String) async throws -> Song { throw URLError(.unknown) }
    func artists() async throws -> [ArtistIndex] { throw URLError(.unknown) }
    func artist(id: String) async throws -> ArtistID3 { throw URLError(.unknown) }
    func album(id: String) async throws -> AlbumID3 { throw URLError(.unknown) }
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
    func allAlbums() async throws -> [AlbumID3] { throw URLError(.unknown) }
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

@Suite("LyricsService — lyric kind classification")
struct LyricsKindTests {
    @Test func libraryPassRechecksLRCAndTextButKeepsKaraoke() {
        let lrc = LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "Hello", start: 0)])])
        let text = LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: false,
            line: [Line(value: "Hello")])])
        let karaoke = LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "Hello", start: 0)], cueLine: [CueLine(index: 0, value: "Hello",
            cue: [LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 5)])])])
        for preference in [LyricsSourcePreference.embedded, .embeddedWithFallback] {
            #expect(!LyricsService.shouldSkipLibraryCache(lrc, preference: preference))
            #expect(!LyricsService.shouldSkipLibraryCache(text, preference: preference))
            #expect(LyricsService.shouldSkipLibraryCache(karaoke, preference: preference))
        }
        #expect(LyricsService.shouldSkipLibraryCache(lrc, preference: .external))
    }
    @Test func karaokeCuesClassifyAsKaraoke() {
        let cue = LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 4)
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [Line(value: "Hello", start: 0)],
                cueLine: [CueLine(index: 0, value: "Hello", cue: [cue])]
            )
        ])
        #expect(LyricsService.kind(of: list) == .karaoke)
    }

    @Test func lineSyncedClassifiesAsSynced() {
        let list = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)])
        ])
        #expect(LyricsService.kind(of: list) == .synced)
    }

    @Test func unsyncedOrEmptyClassifiesAsUnsynced() {
        #expect(LyricsService.kind(of: LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: false, line: [Line(value: "Hello")])
        ])) == .unsynced)
        #expect(LyricsService.kind(of: LyricsList(structuredLyrics: [])) == .unsynced)
    }
}

@Suite("LyricsService — library lyrics generation")
@MainActor
struct LyricsLibraryGenerationTests {
    @Test func streamsSkippedAndMissingOutcomes() async throws {
        let container = try ModelContainer(
            for: Schema([CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let serverId = UUID()

        let cachedList = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)],
                cueLine: [CueLine(index: 0, value: "Hello", cue: [
                    LyricCue(start: 0, value: "Hello", byteStart: 0, byteEnd: 5)
                ])])
        ])
        let data = try JSONEncoder().encode(cachedList)
        await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(CachedLyrics(songId: "cached", serverId: serverId, jsonPayload: data))
            try? ctx.save()
        }

        let service = LyricsService(
            serverService: MockLyricsServerService(),
            modelContainer: container,
            externalProvider: StubExternalLyricsProvider()
        )
        let library = LyricsGenLibraryStub()
        library.songPages[0] = [
            Song(id: "cached", title: "Cached Song", artist: "Artist"),
            Song(id: "missing", title: "Missing Song", artist: "Artist")
        ]

        var events: [LyricsService.LibraryLyricsEvent] = []
        let stream = await service.generateLibraryLyrics(library: library, serverId: serverId)
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(events[0].outcome == .skipped)
        #expect(events[1].outcome == .missing)
        #expect(events.last?.progress.processed == 2)
        #expect(events.last?.progress.total == 2)
        #expect(events.last?.progress.found == 0)
        #expect(events.last?.progress.skipped == 1)
        #expect(events.last?.progress.missing == 1)
    }
}

private actor SlowEnhancedLyricsTransport: HTTPTransport {
    private(set) var requestedEnhanced = false
    private(set) var requestedSongIDs: [String] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let body: String
        if url.path.contains("/ping.") {
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonic":true}}"#
        } else if url.path.contains("getOpenSubsonicExtensions") {
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":[{"name":"songLyrics","versions":[1,2]}]}}"#
        } else {
            requestedEnhanced = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "enhanced" && $0.value == "true" } == true
            let songID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            requestedSongIDs.append(songID)
            if songID == "failed" { throw URLError(.timedOut) }
            if songID == "missing" {
                let empty = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[]}}}"#.utf8)
                return (empty, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            }
            try await Task.sleep(for: .seconds(2))
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[{"lang":"en","synced":true,"line":[{"value":"Hello world","start":0}],"cueLine":[{"index":0,"value":"Hello world","cue":[{"start":0,"end":500,"value":"Hello ","byteStart":0,"byteEnd":6},{"start":500,"end":1000,"value":"world","byteStart":6,"byteEnd":11}]}]}]}}}"#
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

nonisolated private final class RawEnhancedLyricsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              url.path == "/music/rest/getLyricsBySongId.view",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "enhanced" && $0.value == "true" }) == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="0s" end="1s"><span begin="0s" end="0.5s">Hello </span><span begin="0.5s" end="1s">world</span></p></div></body></tt>"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/ttml+xml"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FastLineLyricsProvider: ExternalLyricsProviding {
    func fetchLyrics(match: LyricsMatchInfo) async throws -> LyricsList {
        LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "Hello world", start: 0)])])
    }
}

@MainActor
@Suite("Library enhanced lyrics upgrades")
struct LibraryEnhancedLyricsUpgradeTests {
    @Test func cachedLRCIsUpgradedEvenWhenTTMLArrivesAfterHeadStart() async throws {
        let container = try ModelContainer(for: Schema([CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let server = MockLyricsServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Lyrics", baseURL: "https://lyrics.test/music", username: "test"))
        server.state.activeServer = snapshot
        let transport = SlowEnhancedLyricsTransport()
        server.lyricsClient = SwiftSonicClient(configuration: ServerConfiguration(
            serverURL: URL(string: snapshot.baseURL)!, username: "test", password: "test"
        ), transport: transport, retryPolicy: .none)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawEnhancedLyricsProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = LyricsService(serverService: server, modelContainer: container,
            externalProvider: FastLineLyricsProvider(), rawLyricsSession: session)
        let list = LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "Hello world", start: 0)])])
        let context = ModelContext(container)
        context.insert(CachedLyrics(songId: "upgrade", serverId: snapshot.id,
            jsonPayload: try JSONEncoder().encode(list)))
        try context.save()
        let library = LyricsGenLibraryStub()
        library.songPages[0] = [Song(id: "upgrade", title: "Hello world", artist: "Artist")]
        var outcomes: [LyricsService.LibraryLyricsEvent.Outcome] = []
        for try await event in await service.generateLibraryLyrics(library: library, serverId: snapshot.id) {
            outcomes.append(event.outcome)
        }
        #expect(outcomes == [.found(.karaoke)])
        let enhanced = await transport.requestedEnhanced
        #expect(enhanced)
        let raw = try #require(await service.fetchRawTTML(songId: "upgrade", serverId: snapshot.id))
        #expect(try AppleLyricTTMLParser.parse(data: raw).timing == .word)
        let cached = try await service.fetchLyrics(forSongId: "upgrade", serverId: snapshot.id)
        #expect(LyricsService.kind(of: cached) == .karaoke)
    }
}


@MainActor
private final class CountingExternalLyricsProvider: ExternalLyricsProviding {
    private(set) var calls = 0
    func fetchLyrics(match: LyricsMatchInfo) async throws -> LyricsList {
        calls += 1
        throw LyricsError.notFound
    }
}

@MainActor
@Suite("Server lyrics file generation")
struct ServerLyricsFileGenerationTests {
    @Test func requestsEveryTrackDespiteCacheAndNeverUsesExternalFallback() async throws {
        let container = try ModelContainer(for: Schema([CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let server = MockLyricsServerService()
        let snapshot = ServerSnapshot(from: ServerConfig(displayName: "Lyrics", baseURL: "https://lyrics.test/music", username: "test"))
        server.state.activeServer = snapshot
        let transport = SlowEnhancedLyricsTransport()
        server.lyricsClient = SwiftSonicClient(configuration: ServerConfiguration(
            serverURL: URL(string: snapshot.baseURL)!, username: "test", password: "test"
        ), transport: transport, retryPolicy: .none)
        let provider = CountingExternalLyricsProvider()
        let service = LyricsService(serverService: server, modelContainer: container, externalProvider: provider)
        let cached = LyricsList(structuredLyrics: [StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "Cached", start: 0)], cueLine: [CueLine(index: 0, value: "Cached", cue: [LyricCue(start: 0, value: "Cached", byteStart: 0, byteEnd: 6)])])])
        let context = ModelContext(container)
        context.insert(CachedLyrics(songId: "cached", serverId: snapshot.id, jsonPayload: try JSONEncoder().encode(cached)))
        try context.save()
        let library = LyricsGenLibraryStub()
        library.songPages[0] = ["cached", "missing", "failed"].map { Song(id: $0, title: $0, artist: "Artist") }
        var events: [LyricsService.LibraryLyricsEvent] = []
        for try await event in await service.generateLibraryLyrics(library: library, serverId: snapshot.id, mode: .serverFiles) {
            events.append(event)
        }
        #expect(await transport.requestedSongIDs == ["cached", "missing", "failed"])
        #expect(await transport.requestedEnhanced)
        #expect(provider.calls == 0)
        #expect(events[0].outcome == .found(.karaoke))
        #expect(events[1].outcome == .missing)
        guard case .failed = events[2].outcome else { Issue.record("Timeout must be shown as a request failure"); return }
        #expect(events.last?.progress.skipped == 0)
        #expect(events.last?.progress.found == 1)
        #expect(events.last?.progress.missing == 1)
        #expect(events.last?.progress.failed == 1)

        // A queued run for an account that is no longer active must send nothing.
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.test", username: "test"))
        do {
            for try await _ in await service.generateLibraryLyrics(library: library, serverId: snapshot.id, mode: .serverFiles) {}
            Issue.record("An inactive server's run must cancel")
        } catch is CancellationError {
            #expect(await transport.requestedSongIDs.count == 3)
        }
    }
}
