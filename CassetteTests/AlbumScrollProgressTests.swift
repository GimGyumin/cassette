// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import Foundation
import Testing
@testable import Cassette

@Suite("Album artwork scroll progress")
struct AlbumScrollProgressTests {
    @Test func progressIsDerivedDirectlyFromScrollDistanceAndHeroWidth() {
        let start = AlbumArtworkScrollProgress(distance: 0, width: 390)
        #expect(start.blur == 0 && start.fade == 0)

        let mid = AlbumArtworkScrollProgress(distance: 220, width: 390)
        #expect(mid.blur > 0 && mid.blur < 1)
        #expect(mid.fade > 0 && mid.fade < 1)

        let back = AlbumArtworkScrollProgress(distance: 120, width: 390)
        #expect(back.blur < mid.blur)
        #expect(back.fade < mid.fade)

        let end = AlbumArtworkScrollProgress(distance: 1_000, width: 390)
        #expect(end.blur == 1 && end.fade == 1)

        // A wider artwork needs more scroll distance for the same progress.
        let wide = AlbumArtworkScrollProgress(distance: 220, width: 780)
        #expect(wide.blur < mid.blur)

        let reduced = AlbumArtworkScrollProgress(distance: 220, width: 390, reduceMotion: true)
        #expect(reduced.blur == 0)
        #expect(reduced.fade == mid.fade)
    }
}
