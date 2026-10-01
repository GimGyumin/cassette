// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// Playback modifiers Siri can pass to `playAudio` / `warmupAudioQueue`
/// (“Play X shuffled”, “Play X on repeat”).
///
/// Case names must match the `.audio.playbackAttributes` schema
/// (`shuffle`, `repeat`).
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum CassettePlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [CassettePlaybackAttributes: DisplayRepresentation] = [
        .shuffle: DisplayRepresentation(
            title: LocalizedStringResource("Shuffle", comment: "Playback attribute: shuffle the queue.")
        ),
        .repeat: DisplayRepresentation(
            title: LocalizedStringResource("Repeat", comment: "Playback attribute: repeat the queue.")
        )
    ]
}
