// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Source selection for the Library → Songs list: the whole server library, the starred songs, or the
/// tracks available offline on this device (Apple Music's "All Songs / Favorites / Downloads" menu).
///
/// Each case maps to a different source array inside `SongsListViewModel`; sorting and A–Z grouping
/// are then applied identically to whichever source is active.
nonisolated enum SongListFilter: String, CaseIterable, Sendable {
    case allSongs
    case favorites
    case downloads

    var label: String {
        switch self {
        case .allSongs:
            return String(localized: "All Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .favorites:
            return String(localized: "Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .downloads:
            return String(localized: "Downloads", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    var systemImage: String {
        switch self {
        case .allSongs: return "music.note"
        case .favorites: return "star"
        case .downloads: return "arrow.down.circle"
        }
    }
}
