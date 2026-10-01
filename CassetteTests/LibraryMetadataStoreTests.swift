// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
@testable import Cassette

@Suite("LibraryMetadataStore")
@MainActor
struct LibraryMetadataStoreTests {

    private func makeStore() throws -> (LibraryMetadataStore, UUID) {
        let container = try ModelContainer(
            for: Schema([LibraryMetadataSong.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (LibraryMetadataStore(modelContainer: container), UUID())
    }

    @Test("matching finds a song regardless of its position in the store")
    func matchingFindsSongBeyondArbitraryFetchWindow() throws {
        let (store, serverId) = try makeStore()

        // Insert many filler songs first, then the target LAST. The old implementation
        // ranked only an arbitrary bounded slice (max(limit*8, 100)), so a target this
        // far into the store was silently dropped and Siri fell back to a wrong match.
        var songs: [DisplayableSong] = []
        for i in 0..<400 {
            songs.append(DisplayableSong(id: "filler-\(i)", title: "Filler Track \(i)", artist: "Various Artists"))
        }
        let target = DisplayableSong(id: "billie-jean", title: "Billie Jean", artist: "Michael Jackson")
        songs.append(target)
        store.upsert(songs, serverId: serverId)

        let results = store.matching("billie jean", serverId: serverId, limit: 10)

        #expect(results.first?.id == "billie-jean")
        #expect(results.first?.title == "Billie Jean")
    }

    @Test("exact title match outranks partial matches")
    func exactTitleOutranksPartial() throws {
        let (store, serverId) = try makeStore()
        store.upsert([
            DisplayableSong(id: "partial", title: "Billie Eilish Song", artist: "X"),
            DisplayableSong(id: "exact", title: "Billie", artist: "X")
        ], serverId: serverId)

        let results = store.matching("billie", serverId: serverId, limit: 10)

        #expect(results.first?.id == "exact")
    }

    @Test("album constraint outranks a same-titled single and remix")
    func albumConstraintOutranksVariants() throws {
        let (store, serverId) = try makeStore()
        store.upsert([
            DisplayableSong(
                id: "single",
                title: "Beat It",
                artist: "Michael Jackson",
                albumName: "Beat It - Single"
            ),
            DisplayableSong(
                id: "remix",
                title: "Beat It (Remix)",
                artist: "Michael Jackson",
                albumName: "Thriller"
            ),
            DisplayableSong(
                id: "thriller",
                title: "Beat It",
                artist: "Michael Jackson",
                albumName: "Thriller"
            ),
        ], serverId: serverId)

        let results = store.matching(
            "Beat It from Thriller by Michael Jackson",
            serverId: serverId,
            limit: 10
        )

        #expect(results.first?.id == "thriller")
    }

    @Test("unrequested remix does not outrank the canonical song")
    func canonicalSongOutranksUnrequestedRemix() throws {
        let (store, serverId) = try makeStore()
        store.upsert([
            DisplayableSong(id: "remix", title: "Beat It Remix", artist: "Michael Jackson"),
            DisplayableSong(id: "canonical", title: "Beat It", artist: "Michael Jackson"),
        ], serverId: serverId)

        let results = store.matching("Beat It", serverId: serverId, limit: 10)

        #expect(results.first?.id == "canonical")
    }

    @Test("restored Siri metadata keeps the cover art identifier")
    func restoredSongKeepsCoverArtIdentifier() throws {
        let (store, serverId) = try makeStore()
        store.upsert([
            DisplayableSong(
                id: "song-with-cover",
                title: "Covered Song",
                artist: "Artist",
                coverArtId: "cover-123"
            )
        ], serverId: serverId)

        let restored = store.song(id: "song-with-cover", serverId: serverId)

        #expect(restored?.coverArtId == "cover-123")
    }
}
