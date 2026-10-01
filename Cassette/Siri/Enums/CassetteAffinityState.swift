// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// Like / dislike / cleared state for an audio item.
///
/// Case names must match the `.audio.affinityState` schema (`like`, `dislike`,
/// `unset`) — verified against `AppIntentSchemas.sqlite`.
///
/// Cassette has no dislike state: `dislike` deliberately maps onto
/// “remove the favorite” in `UpdateAudioAffinityIntent`.
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.affinityState)
enum CassetteAffinityState: String {
    case like
    case dislike
    case unset

    static let caseDisplayRepresentations: [CassetteAffinityState: DisplayRepresentation] = [
        .like: DisplayRepresentation(
            title: LocalizedStringResource("Like", comment: "Affinity state: the song is favorited.")
        ),
        .dislike: DisplayRepresentation(
            title: LocalizedStringResource("Dislike", comment: "Affinity state: the song is not wanted.")
        ),
        .unset: DisplayRepresentation(
            title: LocalizedStringResource("Unset", comment: "Affinity state: no explicit opinion.")
        )
    ]
}
