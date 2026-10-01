// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Why a queue transition was — or was not — handed to the engine's pre-buffered queue.
///
/// Carrying the reason as a value keeps the policy pure and testable, and turns "why did I hear a
/// gap?" into one debug line on the device.
nonisolated enum GaplessDecision: String, Equatable, Sendable {
    /// Arm the AudioStreaming queue so the next track follows without a gap.
    case bridge
    /// The crossfade owns this transition: it restarts the engine to fade in, which a queued
    /// continuation cannot do.
    case crossfade
    /// The user turned gapless playback off.
    case disabledByUser
    /// Multichannel / Atmos is routed through AVPlayer, which cannot continue this engine's queue.
    case requiresSystemPlayer
    /// Nothing follows the current track.
    case endOfQueue
    /// Metered network, remote next track, and the user did not allow prefetching over cellular.
    case meteredNetwork
    /// The device is thermally or memory constrained: buffering ahead is not worth it right now.
    case deviceConstrained
}

/// Pure gapless policy.
///
/// `PlayerService` owns the engine and the queue; this type owns the *decision* of whether the
/// engine may be given the next track ahead of time, and it is unit-tested
/// (`GaplessPolicyTests`).
nonisolated enum GaplessPolicy {
    /// The classic "album gapless" pair: same album, consecutive track numbers.
    ///
    /// Used for two things: arming the bridge, and the crossfade exemption ("Disable for gapless
    /// albums" — a mastered album must not be blurred into a crossfade).
    static func isAlbumPair(
        currentAlbumId: String?,
        currentTrackNumber: Int?,
        nextAlbumId: String?,
        nextTrackNumber: Int?
    ) -> Bool {
        guard let currentAlbumId, let nextAlbumId,
              let currentTrackNumber, let nextTrackNumber else { return false }
        return currentAlbumId == nextAlbumId && nextTrackNumber == currentTrackNumber + 1
    }

    /// Arbitration for one transition.
    ///
    /// Order matters and is deliberate:
    /// 1. a transition that cannot happen at all beats one that is merely disallowed,
    /// 2. an active crossfade is resolved before the gapless flag, so toggling gapless never
    ///    silently changes whether the crossfade runs (except for its explicit album exception),
    /// 3. the metered-network rule is checked before the device budget because it is about the
    ///    user's data plan, not the device's temperature.
    static func decision(
        hasNextTrack: Bool,
        crossfadeDuration: Double,
        crossfadeDisabledForAlbumPairs: Bool,
        isAlbumPair: Bool,
        requiresSystemPlayer: Bool,
        gaplessEnabled: Bool,
        isMeteredNetwork: Bool,
        nextSourceIsLocal: Bool,
        allowMeteredNetwork: Bool,
        deviceAllowsPrebuffer: Bool
    ) -> GaplessDecision {
        guard hasNextTrack else { return .endOfQueue }
        if crossfadeDuration > 0 {
            // A gapless album pair stays seamless unless the user asked the crossfade to win.
            guard crossfadeDisabledForAlbumPairs && isAlbumPair else { return .crossfade }
        }
        guard !requiresSystemPlayer else { return .requiresSystemPlayer }
        guard gaplessEnabled else { return .disabledByUser }
        // A local file costs nothing to pre-buffer, so the data-plan rule only applies to streams.
        if isMeteredNetwork, !nextSourceIsLocal, !allowMeteredNetwork {
            return .meteredNetwork
        }
        guard deviceAllowsPrebuffer else { return .deviceConstrained }
        return .bridge
    }
}
