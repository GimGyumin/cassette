// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

//
//  CassetteTests.swift
//  CassetteTests
//
//  Created by Mathieu Dubart on 24/04/2026.
//

import Foundation
import Testing
@testable import Cassette

struct CassetteTests {

    @Test func streamingSettings_dropsTheRetiredPlaybackRouteKey() {
        // The Server Playback Method menu is gone, so a route written by an older build must not
        // stay behind in UserDefaults where it could look like a live setting.
        UserDefaults.standard.set("hls", forKey: "cassette.streaming.jellyfinRoute")
        _ = StreamingSettings()
        #expect(UserDefaults.standard.string(forKey: "cassette.streaming.jellyfinRoute") == nil)
    }

    @Test func streamingSettings_honorsLosslessSelection() {
        let settings = StreamingSettings()
        let previousWiFiFormat = settings.wifiFormat
        defer { settings.wifiFormat = previousWiFiFormat }

        settings.wifiFormat = .flacOriginal

        #expect(settings.formatForCurrentNetwork(isLimited: false) == .flacOriginal)
    }

    @Test func playerService_detectsEngineProgressWrappingToStart() {
        #expect(
            PlayerService.didEngineProgressWrap(previous: 50, current: 0.2)
        )

        #expect(
            !PlayerService.didEngineProgressWrap(previous: 50, current: 45)
        )
    }

    @Test func displayableSong_normalizesMissingCoverIdentifier() {
        let blankCover = DisplayableSong(
            id: "song-fallback",
            title: "Song",
            coverArtId: "  \n"
        )
        #expect(blankCover.explicitCoverArtId == nil)
        #expect(blankCover.effectiveCoverArtId == "song-fallback")

        let explicitCover = DisplayableSong(
            id: "song-id",
            title: "Song",
            coverArtId: " album-cover "
        )
        #expect(explicitCover.explicitCoverArtId == "album-cover")
        #expect(explicitCover.effectiveCoverArtId == "album-cover")
    }

    @Test func displayableSong_formatsExplicitAdvisoryLikeMusic() {
        let explicit = DisplayableSong(
            id: "explicit",
            title: "Explicit Track",
            explicitStatus: "explicit"
        )
        #expect(explicit.contentAdvisoryLabel(locale: Locale(identifier: "ko_KR")) == "19")
        #expect(explicit.contentAdvisoryLabel(locale: Locale(identifier: "en_US")) == "E")

        let literalE = DisplayableSong(id: "e", title: "E Track", explicitStatus: "E")
        let clean = DisplayableSong(id: "clean", title: "Clean Track", explicitStatus: "notExplicit")
        #expect(literalE.contentAdvisoryLabel(locale: Locale(identifier: "ko_KR")) == "E")
        #expect(clean.contentAdvisoryLabel(locale: Locale(identifier: "ko_KR")) == nil)
    }

}
