// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Where Cassette should load lyrics from.
nonisolated enum LyricsSourcePreference: String, CaseIterable, Identifiable, Sendable {
    /// OpenSubsonic / server lyrics only.
    case embedded = "embedded"
    /// External provider (LRCLIB) only.
    case external = "external"
    /// Server first; fetch external when missing or weaker (unsynced / no karaoke).
    case embeddedWithFallback = "embeddedWithFallback"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded:
            return String(localized: "Server only", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .external:
            return String(localized: "External (LRCLIB)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .embeddedWithFallback:
            return String(localized: "Server first, then external", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    var detail: String {
        switch self {
        case .embedded:
            return String(localized: "Only use lyrics from your music server (not file-tag embeds alone).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .external:
            return String(localized: "Always fetch from LRCLIB (prefers synced lyrics).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .embeddedWithFallback:
            return String(localized: "Prefer server lyrics; use LRCLIB when missing, unsynced, or without karaoke.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    static let userDefaultsKey = "cassette.lyrics.source"
    /// Default: server lyrics first, then external upgrade.
    static let `default`: LyricsSourcePreference = .embeddedWithFallback

    static func current(from defaults: UserDefaults = .standard) -> LyricsSourcePreference {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let value = LyricsSourcePreference(rawValue: raw) else {
            return .default
        }
        return value
    }
}

/// Metadata used to match a track on an external lyrics provider.
nonisolated struct LyricsMatchInfo: Sendable, Equatable {
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int

    init(title: String, artist: String?, album: String?, durationSeconds: Int) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = max(0, durationSeconds)
    }

    init(song: DisplayableSong) {
        let duration = song.duration > 0 ? Int(song.duration.rounded()) : 0
        self.init(
            title: song.title,
            artist: song.artist,
            album: song.albumName,
            durationSeconds: duration
        )
    }

    var canQueryExternal: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
