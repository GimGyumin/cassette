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

    @Test @MainActor func streamingSettings_persistsAndReloadsManualPlaybackRoute() throws {
        let suite = "CassetteRouteTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StreamingSettings(defaults: defaults)
        #expect(settings.jellyfinRoute == .automatic)
        settings.adaptiveCeiling = .aac128
        settings.jellyfinRoute = .hls
        #expect(settings.adaptiveCeiling == nil)
        #expect(StreamingSettings(defaults: defaults).jellyfinRoute == .hls)
        defaults.set("originalFile", forKey: "cassette.streaming.jellyfinRoute")
        settings.reloadFromDefaults()
        #expect(settings.jellyfinRoute == .originalFile)
        defaults.set("unknown", forKey: "cassette.streaming.jellyfinRoute")
        #expect(StreamingSettings(defaults: defaults).jellyfinRoute == .automatic)
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

    @Test func albumArtworkFallbackPreservesExplicitAlternateCoversAndMetadata() {
        let missing = DisplayableSong(id: "one", title: "One", albumId: "album", duration: 120, coverArtId: " ", bitRate: 1400)
        let resolved = missing.withFallbackCoverArtID(" album-cover ")
        #expect(resolved.explicitCoverArtId == "album-cover")
        #expect(resolved.id == missing.id && resolved.duration == missing.duration && resolved.bitRate == missing.bitRate)
        let alternate = DisplayableSong(id: "two", title: "Two", coverArtId: "different-cover")
        #expect(alternate.withFallbackCoverArtID("album-cover") == alternate)
        #expect(missing.withFallbackCoverArtID(" ") == missing)
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
