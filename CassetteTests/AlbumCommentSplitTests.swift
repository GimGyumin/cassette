// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

// MARK: - Comment copyright/description splitting

// Verifies that a single OpenSubsonic `comment` string carrying both an album
// description and an ID3 `TCOP`/`TPUB` copyright block is separated the way Apple Music
// does: copyright → footer, description → About block.
struct AlbumCommentSplitTests {

    @Test("description then copyright separates both")
    func descriptionThenCopyright() {
        let comment = """
        A band's third studio album.

        ℗ 2024 XL Recordings
        © 2024 XL Recordings
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings\n© 2024 XL Recordings")
        #expect(result.description == "A band's third studio album.")
    }

    @Test("copyright only leaves description empty")
    func copyrightOnly() {
        let comment = "℗ 2024 XL Recordings"
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings")
        #expect(result.description == nil)
    }

    @Test("description only leaves copyright empty")
    func descriptionOnly() {
        let comment = "A band's third studio album."
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == nil)
        #expect(result.description == "A band's third studio album.")
    }

    @Test("copyright then description separates both")
    func copyrightThenDescription() {
        let comment = """
        © 2024 XL Recordings

        A band's third studio album.
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "© 2024 XL Recordings")
        #expect(result.description == "A band's third studio album.")
    }

    @Test("multi-line WARNING block stays inside copyright")
    func multiLineWarningBlock() {
        let comment = """
        ℗ 2024 XL Recordings
        WARNING: All rights reserved.
        Unauthorized copying is prohibited.

        The album was recorded in London.
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings\nWARNING: All rights reserved.\nUnauthorized copying is prohibited.")
        #expect(result.description == "The album was recorded in London.")
    }

    @Test("multiple copyright blocks uses the first")
    func multipleCopyrightBlocks() {
        let comment = """
        © 2024 XL Recordings

        Some descriptive text.

        ℗ 2024 XL Recordings
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "© 2024 XL Recordings")
        #expect(result.description == "Some descriptive text.")
    }

    @Test("marker words open a copyright block")
    func markerWords() {
        #expect(AlbumDetailViewModel.splitComment("copyright 2024 XL").copyright == "copyright 2024 XL")
        #expect(AlbumDetailViewModel.splitComment("(p) 2024 XL").copyright == "(p) 2024 XL")
        #expect(AlbumDetailViewModel.splitComment("p 2024 XL").copyright == "p 2024 XL")
        #expect(AlbumDetailViewModel.splitComment("℗ 2024 XL").copyright == "℗ 2024 XL")
        #expect(AlbumDetailViewModel.splitComment("® 2024 XL").copyright == "® 2024 XL")
    }

    @Test("nil comment splits to both nil")
    func nilComment() {
        let result = AlbumDetailViewModel.splitComment(nil)
        #expect(result.copyright == nil)
        #expect(result.description == nil)
    }

    @Test("findTrackCopyright returns only the copyright block of the first matching track")
    func findTrackCopyrightStripsDescription() {
        let comments = [
            "Ordinary track comment.",
            "Recorded in London.\n\n℗ 2024 XL Recordings\n© 2024 XL Recordings",
            "℗ 2024 Another Label",
        ]
        #expect(AlbumDetailViewModel.findTrackCopyright(comments) == "℗ 2024 XL Recordings\n© 2024 XL Recordings")
    }

    @Test("descriptionFromSongComments strips copyright from the shared description")
    func descriptionFromSongCommentsStripsCopyright() {
        let shared = "A band's third studio album.\n\n℗ 2024 XL Recordings"
        let songs = [
            Song(id: "1", title: "Track A", comment: shared),
            Song(id: "2", title: "Track B", comment: shared),
        ]
        #expect(AlbumDetailViewModel.descriptionFromSongComments(songs) == "A band's third studio album.")
    }

    // MARK: - Explicit [[COPYRIGHT]] marker blocks

    @Test("[[COPYRIGHT]] block is authoritative and removed from description")
    func explicitCopyrightBlock() {
        let comment = """
        A band's third studio album.

        [[COPYRIGHT]]
        ℗ 2024 XL Recordings
        © 2024 XL Recordings
        [[/COPYRIGHT]]
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings\n© 2024 XL Recordings")
        #expect(result.description == "A band's third studio album.")
    }

    @Test("[[COPYRIGHT]] block without surrounding heuristic markers")
    func explicitCopyrightBlockWithoutSymbols() {
        let comment = """
        Recorded in London over two weeks.

        [[COPYRIGHT]]
        Released under exclusive license to Example Label Ltd.
        [[/COPYRIGHT]]
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "Released under exclusive license to Example Label Ltd.")
        #expect(result.description == "Recorded in London over two weeks.")
    }

    @Test("marker block wins over heuristic line markers")
    func markerBlockWinsOverHeuristics() {
        let comment = """
        Some description mentioning ℗ casually in line.

        [[COPYRIGHT]]
        ℗ 2024 XL Recordings
        [[/COPYRIGHT]]
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings")
        #expect(result.description == "Some description mentioning ℗ casually in line.")
    }

    @Test("empty marker block yields nil copyright and keeps description")
    func emptyMarkerBlock() {
        let comment = """
        Just a description.

        [[COPYRIGHT]]
        [[/COPYRIGHT]]
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == nil)
        #expect(result.description == "Just a description.")
    }

    @Test("multiple marker blocks use the first and strip all")
    func multipleMarkerBlocks() {
        let comment = """
        [[COPYRIGHT]]
        ℗ 2024 XL Recordings
        [[/COPYRIGHT]]

        Some description.

        [[COPYRIGHT]]
        Second block.
        [[/COPYRIGHT]]
        """
        let result = AlbumDetailViewModel.splitComment(comment)
        #expect(result.copyright == "℗ 2024 XL Recordings")
        #expect(result.description == "Some description.")
    }
}
