// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Groups remasters / anniversary / deluxe editions of the same album work
/// (e.g. *Thriller* and *Thriller 25*) from an artist’s album list.
nonisolated enum AlbumVersionMatcher {
    /// Common anniversary / special-edition year markers appended to titles.
    private static let anniversaryMarkers: Set<String> = [
        "10", "15", "20", "25", "30", "35", "40", "45", "50", "60"
    ]

    /// Returns sibling editions of `currentName` among `albums`, excluding `excludingId`.
    static func otherVersions(
        of currentName: String,
        excludingId: String,
        among albums: [AlbumID3]
    ) -> [AlbumID3] {
        let base = canonicalTitle(currentName)
        guard !base.isEmpty else { return [] }
        return albums.filter { album in
            album.id != excludingId && canonicalTitle(album.name) == base
        }
    }

    /// True when `raw` is an "original" title — i.e. carrying no edition / remaster /
    /// anniversary / deluxe marker that ``canonicalTitle`` would strip.
    static func isOriginalName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let base = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Original iff canonically stripping edition markers leaves the name untouched.
        return canonicalTitle(raw) == base
    }

    /// Strips edition / remaster / anniversary suffixes so related releases share one key.
    static func canonicalTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // Drop bracketed / parenthetical edition tags: "(Deluxe Edition)", "[Remastered]".
        let bracketPattern = #"[\(\[][^\)\]]*[\)\]]"#
        while let range = s.range(of: bracketPattern, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Trailing edition phrases after space / dash / colon.
        let editionSuffix = #"(?i)[\s:\-–—]+((super\s+)?deluxe|expanded|remaster(ed)?|anniversary|special|bonus|collector'?s?|limited|complete|definitive|legacy|reissue|japanese|instrumental|acoustic|demo|mono|stereo)(\s+(edition|version))?$"#
        while let range = s.range(of: editionSuffix, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // "25th Anniversary", "20th Anniversary Edition"
        let ordinalAnniversary = #"(?i)[\s:\-–—]+\d{1,2}(st|nd|rd|th)\s*(anniversary)?(\s+(edition|version))?$"#
        if let range = s.range(of: ordinalAnniversary, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // "Thriller 25" / "Album 40" — only known anniversary markers, keep short titles intact.
        if let range = s.range(of: #"\s+(\d{2})$"#, options: .regularExpression) {
            let marker = String(s[range]).trimmingCharacters(in: .whitespaces)
            let remainder = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if anniversaryMarkers.contains(marker), remainder.count >= 3 {
                s = remainder
            }
        }

        // Leftover " - Deluxe Edition" tails that didn't match the simpler suffix list.
        let editionDashTail = #"(?i)\s+[\-–—]\s+.*(edition|version|remaster|deluxe|anniversary|expanded).*$"#
        if let range = s.range(of: editionDashTail, options: .regularExpression) {
            let before = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if before.count >= 3 {
                s = before
            }
        }

        return s
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Subtitle for an edition card: OpenSubsonic `version`, else year.
    static func editionSubtitle(for album: AlbumID3) -> String? {
        if let version = album.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            if let year = album.year {
                return "\(version) · \(year)"
            }
            return version
        }
        if let year = album.year {
            return String(year)
        }
        return nil
    }
}
