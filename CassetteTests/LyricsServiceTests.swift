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
    func addServer(displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func addServerWithJellyfinToken(displayName: String, baseURL: String, username: String, jellyfinAccessToken: String, customHeaders: [String: String]) async throws {}
    func removeServer(id: UUID) async throws {}
    func setActiveServer(id: UUID) async throws {}
    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {}
    func updateServer(id: UUID, displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func testConnection() async throws {}
    func testConnection(url: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func makeSwiftSonicClient() async throws -> SwiftSonicClient { throw CassetteError.notImplemented }
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
            StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)])
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
