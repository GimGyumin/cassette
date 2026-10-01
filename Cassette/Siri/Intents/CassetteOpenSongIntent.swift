// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Opens a song in the host app via a `cassette://` deep link.
///
/// The `.audio` domain has no `openAudio` schema in this SDK, so this uses the
/// system `.system.open` schema with `OpenIntent` (Apple's own CosmoTunes
/// sample takes the same route). Songs are the primary openable content;
/// album/artist/playlist navigation remains reachable through `playAudio`.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct CassetteOpenSongIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Song"

    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var target: CassetteSongEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = CassetteEntityID(rawValue: target.id),
           let url = CassetteDeepLink.url(kind: .song, id: id) {
            await SiriBridge.openURLAction?(url)
        }
        return .result()
    }
}
