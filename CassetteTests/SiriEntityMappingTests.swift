// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

// MARK: - Entity identifier namespace

@Suite("CassetteEntityID")
struct CassetteEntityIDTests {
    @Test("round-trips through rawValue")
    func roundTrips() {
        let server = UUID()
        let id = CassetteEntityID(serverId: server, localId: "abc123")
        #expect(CassetteEntityID(rawValue: id.rawValue) == id)
    }

    @Test("local id may contain colons")
    func localIdMayContainColon() {
        let server = UUID()
        let id = CassetteEntityID(serverId: server, localId: "song:with:colons")
        #expect(CassetteEntityID(rawValue: id.rawValue)?.localId == "song:with:colons")
    }

    @Test("rejects malformed raw values")
    func rejectsMalformed() {
        #expect(CassetteEntityID(rawValue: "") == nil)
        #expect(CassetteEntityID(rawValue: "not-a-uuid:xyz") == nil)
        #expect(CassetteEntityID(rawValue: "noColonHere") == nil)
    }

    @Test("two servers do not collide for the same local id")
    func distinctServersDoNotCollide() {
        let serverA = UUID()
        let serverB = UUID()
        let idA = CassetteEntityID(serverId: serverA, localId: "1234")
        let idB = CassetteEntityID(serverId: serverB, localId: "1234")
        #expect(idA != idB)
        #expect(idA.rawValue != idB.rawValue)
    }
}

// MARK: - Song entity mapping

// Swift Testing cannot apply `@Suite` / `@Test` to declarations that carry an
// availability annotation, so the iOS 27 schema types are guarded inside each
// test body instead. On an older OS the tests return early (nothing to assert).
@MainActor
@Suite("CassetteSongEntity mapping")
struct CassetteSongEntityMappingTests {
    private func makeSong() -> DisplayableSong {
        DisplayableSong(
            id: "song1",
            title: "Billie Jean",
            artist: "Michael Jackson",
            albumId: "album1",
            albumName: "Thriller",
            artistId: "artist1",
            duration: 294,
            isrc: "USSM18200001",
            displayComposer: "Michael Jackson"
        )
    }

    @Test("maps the core schema fields")
    func mapsCoreFields() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let server = UUID()
        let entity = CassetteSongEntity(song: makeSong(), serverId: server)

        #expect(entity.title == "Billie Jean")
        #expect(entity.artistName == "Michael Jackson")
        #expect(entity.albumTitle == "Thriller")
        #expect(entity.composerName == "Michael Jackson")
        #expect(entity.internationalStandardRecordingCode == "USSM18200001")
        #expect(entity.duration == 294)
        #expect(entity.id == CassetteEntityID(serverId: server, localId: "song1").rawValue)
    }

    @Test("resolves artist and album relations by id")
    func mapsRelations() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let server = UUID()
        let entity = CassetteSongEntity(song: makeSong(), serverId: server)

        #expect(entity.artists.count == 1)
        #expect(entity.artists.first?.name == "Michael Jackson")
        #expect(entity.artists.first?.id == CassetteEntityID(serverId: server, localId: "artist1").rawValue)
        #expect(entity.album?.title == "Thriller")
    }

    @Test("missing artist falls back to the schema-safe default and empty relations")
    func missingArtistFallsBack() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let song = DisplayableSong(id: "s", title: "T")
        let entity = CassetteSongEntity(song: song, serverId: UUID())

        #expect(entity.artistName == CassetteEntityDisplay.unknownArtist)
        #expect(entity.artists.isEmpty)
        #expect(entity.album == nil)
        #expect(entity.composers.isEmpty)
    }

    @Test("loadRelations false omits the relation graph")
    func loadRelationsFalseOmitsRelations() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let server = UUID()
        let entity = CassetteSongEntity(song: makeSong(), serverId: server, loadRelations: false)

        #expect(entity.artists.isEmpty)
        #expect(entity.album == nil)
        #expect(entity.composers.isEmpty)
        // Flat fields still resolve.
        #expect(entity.title == "Billie Jean")
    }
}
