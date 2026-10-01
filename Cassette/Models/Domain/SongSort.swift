// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// User-selectable ordering for the Library → Songs list. String-backed so it persists via
/// `@AppStorage("cassette.songSort")`, mirroring `AlbumSort` / `ArtistSort`.
///
/// Sorting is client-side on already-fetched songs, so a single ordering works identically for the
/// full library, the favorites source, and the local downloads source.
nonisolated enum SongSort: String, CaseIterable, Sendable {
    case title
    case dateAdded
    case artist

    var label: String {
        switch self {
        case .title:
            return String(localized: "Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .dateAdded:
            return String(localized: "Date Added", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .artist:
            return String(localized: "Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .dateAdded: return "calendar"
        case .artist: return "music.mic"
        }
    }

    /// Secondary line rendered under the label in the sort menu (Apple Music labels the artist
    /// ordering "A–Z" because sections are keyed on the artist name).
    var subtitle: String? {
        self == .artist ? "A–Z" : nil
    }

    /// Only the alphabetical orderings group the list into lettered sections (and therefore show the
    /// alphabet jump bar). "Date Added" is a single newest-first list, as in Apple Music.
    var groupsAlphabetically: Bool {
        self != .dateAdded
    }

    /// Value used for the A–Z section header — and for the section's internal ordering — of a song.
    /// Songs without an artist fall into the trailing "#" section.
    func groupingKey(for song: DisplayableSong) -> String {
        switch self {
        case .title, .dateAdded:
            return song.title
        case .artist:
            return song.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}
