// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// Marker result that satisfies the audio domain's queue-warmup contract.
///
/// `warmupAudioQueue` returns this value and `playAudio` accepts it back, which
/// lets the system prime a queue without starting playback.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct CassetteWarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(
                "Warmup Audio Queue Result",
                comment: "Diagnostic title; only visible in App Intents debugging UI."
            )
        )
    }

    init() {}
}
