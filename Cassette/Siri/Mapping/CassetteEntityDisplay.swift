// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Localized fallbacks for schema properties that are non-optional.
///
/// `.audio.song` requires `artistName`; `.audio.album` requires `artistName`
/// and `artists`. Servers occasionally omit artist tags, so the mappers need a
/// stable, localized stand-in instead of an empty string.
nonisolated enum CassetteEntityDisplay {
    static var unknownArtist: String {
        String(
            localized: "Unknown Artist",
            bundle: AppUILanguage.localizationBundle,
            locale: AppUILanguage.locale
        )
    }

    /// Resolves a display artist name, falling back to the schema-safe default.
    static func artistName(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unknownArtist
        }
        return raw
    }
}
