// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// The owner of a playlist.
///
/// The `.audio.playlist` schema types `owner` as a union of a person and a name
/// (`person` / `name`); Navidrome exposes the owner as a plain username string.
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum CassettePlaylistOwner {
    case person(IntentPerson)
    case name(String)
}
