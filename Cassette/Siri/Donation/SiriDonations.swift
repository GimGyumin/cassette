// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Stateless donation helpers.
///
/// Apple's guidance (CosmoTunes `DonationManager`): donate from **UI tap sites**
/// after the person completes an action, never from inside an intent's
/// `perform()` — the framework already donates intents invoked through Siri or
/// Shortcuts. Donate only actions with real recommendation value, not every
/// playback.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
enum SiriDonations {
    /// Donates a play-audio intent for a single song the person played in-app.
    static func donatePlay(song: DisplayableSong, serverId: UUID) {
        let entity = CassetteSongEntity(song: song, serverId: serverId, loadRelations: false)
        let intent = CassettePlayAudioIntent()
        intent.audioEntity = .song(entity)
        intent.playbackAttributes = []
        intent.queueLocation = nil
        intent.warmupAudioQueueResult = nil
        _ = IntentDonationManager.shared.donate(intent: intent)
    }

    /// Donates an affinity intent for a song the person liked/unliked in-app.
    static func donateAffinity(song: DisplayableSong, serverId: UUID, isLiked: Bool) {
        let entity = CassetteSongEntity(song: song, serverId: serverId, loadRelations: false)
        let intent = CassetteUpdateAudioAffinityIntent()
        intent.target = .song(entity)
        intent.affinityState = isLiked ? .like : .unset
        _ = IntentDonationManager.shared.donate(intent: intent)
    }
}
