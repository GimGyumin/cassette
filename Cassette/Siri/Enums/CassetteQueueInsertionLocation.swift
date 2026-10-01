// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// Where a requested item lands in the playback queue when it is already playing.
///
/// Case names must match the `.audio.queueInsertionLocation` schema
/// (`next`, `tail`).
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum CassetteQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [CassetteQueueInsertionLocation: DisplayRepresentation] = [
        .next: DisplayRepresentation(
            title: LocalizedStringResource("Next", comment: "Insert right after the current track.")
        ),
        .tail: DisplayRepresentation(
            title: LocalizedStringResource("Last", comment: "Append to the end of the queue.")
        )
    ]
}
