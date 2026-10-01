// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Locale-safe count labels. Avoid English `"song" + "s"` concatenation — that produces
/// broken Korean like "3곡s" when the base noun is translated but the plural suffix is not.
nonisolated enum CassetteCountLabel {
    static func songs(_ count: Int) -> String {
        String(localized: "\(count) songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    static func albums(_ count: Int) -> String {
        String(localized: "\(count) albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    static func tracks(_ count: Int) -> String {
        String(localized: "\(count) tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    static func songsWithDuration(count: Int, durationLabel: String) -> String {
        String(localized: "\(count) songs, \(durationLabel)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    static func removeSongsConfirm(_ count: Int) -> String {
        String(localized: "Remove \(count) songs?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}
