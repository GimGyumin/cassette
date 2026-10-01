// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

nonisolated enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case error(CassetteError)

    nonisolated static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.playing, .playing), (.paused, .paused):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}

/// What a transport's play/pause control renders for a given `PlaybackState`.
nonisolated enum PlaybackControlAppearance: Sendable, Equatable {
    /// No audio yet: a play request is still being resolved, opened or buffered.
    case loading
    case play
    case pause
}

extension PlaybackState {
    /// Appearance of the play/pause control.
    ///
    /// `.loading` must never render as the pause/stop glyph. A stream that is still being
    /// resolved or buffered has produced no audio: a stop-looking control both claims playback
    /// that is not happening and invites a tap that cannot do what its glyph promises. Every
    /// transport therefore renders `.loading` as the plain **play** glyph — no spinner — in an
    /// inert state, and `.playing` has to mean "audio is really flowing" — see
    /// `PlayerService.publishEnginePlaybackConfirmation` for the confirmation paths.
    var controlAppearance: PlaybackControlAppearance {
        switch self {
        case .loading: return .loading
        case .playing: return .pause
        case .idle, .paused, .error: return .play
        }
    }

    /// The state to publish once an engine confirms it is producing audio, or `nil` to leave the
    /// published state untouched.
    ///
    /// Only a pending `.loading` start is promoted. `.paused` is a user decision that a late
    /// engine callback must not undo, and a session restore that is about to pause itself
    /// (`restoringIntoPause`) must not flash the pause control on its way there.
    func confirmingPlayback(restoringIntoPause: Bool) -> PlaybackState? {
        guard !restoringIntoPause, self == .loading else { return nil }
        return .playing
    }
}
