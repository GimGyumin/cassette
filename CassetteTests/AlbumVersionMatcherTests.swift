// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import SwiftSonic
@testable import Cassette

@Suite("AlbumVersionMatcher")
struct AlbumVersionMatcherTests {

    @Test func thrillerAndThriller25_shareCanonicalTitle() {
        #expect(AlbumVersionMatcher.canonicalTitle("Thriller") == "thriller")
        #expect(AlbumVersionMatcher.canonicalTitle("Thriller 25") == "thriller")
        #expect(
            AlbumVersionMatcher.canonicalTitle("Thriller (25th Anniversary Edition)") == "thriller"
        )
    }

    @Test func deluxeAndRemaster_stripToBase() {
        #expect(AlbumVersionMatcher.canonicalTitle("Random Access Memories (Deluxe Edition)") == "random access memories")
        #expect(AlbumVersionMatcher.canonicalTitle("AM - Remastered") == "am")
    }

    @Test func unrelatedAlbums_doNotMatch() {
        let albums = [
            AlbumID3(id: "1", name: "Thriller 25", songCount: 10, duration: 100, year: 2008),
            AlbumID3(id: "2", name: "Bad", songCount: 10, duration: 100, year: 1987),
            AlbumID3(id: "3", name: "Thriller (Deluxe)", songCount: 12, duration: 120, year: 2001),
        ]
        let versions = AlbumVersionMatcher.otherVersions(
            of: "Thriller",
            excludingId: "0",
            among: albums
        )
        #expect(Set(versions.map(\.id)) == ["1", "3"])
    }

    @Test func shortNumericTitles_areNotStripped() {
        // Adele "21" must not collapse to empty / unrelated matches.
        #expect(AlbumVersionMatcher.canonicalTitle("21") == "21")
    }

    @Test func editionSubtitle_prefersVersionThenYear() {
        let withVersion = AlbumID3(
            id: "1",
            name: "Thriller 25",
            songCount: 1,
            duration: 1,
            year: 2008,
            version: "25th Anniversary"
        )
        #expect(AlbumVersionMatcher.editionSubtitle(for: withVersion) == "25th Anniversary · 2008")

        let yearOnly = AlbumID3(id: "2", name: "Thriller", songCount: 1, duration: 1, year: 1982)
        #expect(AlbumVersionMatcher.editionSubtitle(for: yearOnly) == "1982")
    }
}
