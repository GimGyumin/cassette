// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

nonisolated enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    /// The current track has started, but its engine needs more audio data.
    case buffering
    /// Reopening the current track after a playback failure, retaining its position.
    case recovering
    case playing
    case paused
    case error(CassetteError)

    nonisolated static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.buffering, .buffering),
             (.recovering, .recovering), (.playing, .playing), (.paused, .paused):
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
    /// A play request is still opening; show its active intent and allow cancellation.
    case loading
    case play
    case pause

    nonisolated var systemImage: String { self == .play ? "play.fill" : "pause.fill" }
}

extension PlaybackState {
    /// Keep the player visually active while a requested track is opening. This is
    /// display intent, not confirmation that audio samples have started flowing.
    nonisolated var hasPlaybackIntent: Bool { self == .playing || isAwaitingAudio }

    nonisolated var isAwaitingAudio: Bool {
        self == .loading || self == .buffering || self == .recovering
    }

    /// Engine waits preserve user pause and the reason the request is pending.
    nonisolated func waitingForAudio() -> PlaybackState? {
        switch self {
        case .playing: return .buffering
        case .loading, .buffering, .recovering: return self
        case .idle, .paused, .error: return nil
        }
    }

    nonisolated func resuming(reopensSource: Bool, position: TimeInterval) -> PlaybackState {
        if reopensSource { return position > 0 ? .recovering : .loading }
        return isAwaitingAudio ? self : .playing
    }

    /// Appearance of the play/pause control.
    ///
    /// Waiting phases remain distinct from confirmed playback so progress and Now Playing
    /// timing stay honest, while transports can offer a pause action for the pending request.
    nonisolated var controlAppearance: PlaybackControlAppearance {
        switch self {
        case .loading, .buffering, .recovering: return .loading
        case .playing: return .pause
        case .idle, .paused, .error: return .play
        }
    }

    /// The state to publish once an engine confirms it is producing audio, or `nil` to leave the
    /// published state untouched.
    ///
    /// Only a pending audio request is promoted. `.paused` is a user decision that a late
    /// engine callback must not undo, and a session restore that is about to pause itself
    /// (`restoringIntoPause`) must not flash the pause control on its way there.
    nonisolated func confirmingPlayback(restoringIntoPause: Bool) -> PlaybackState? {
        guard !restoringIntoPause, isAwaitingAudio else { return nil }
        return .playing
    }
}

/// The seek target and its lifetime are one operation, so clearing a seek cannot
/// leave an orphaned deadline. This is independent of transport (paused seeks work).
nonisolated enum PlaybackSeekState: Sendable, Equatable {
    case idle
    case settling(target: TimeInterval, deadline: Date)

    nonisolated var target: TimeInterval? {
        guard case .settling(let target, _) = self else { return nil }
        return target
    }

    nonisolated enum Resolution: Sendable, Equatable {
        case inactive
        case waiting(TimeInterval)
        case finished(target: TimeInterval, landed: Bool)
    }

    nonisolated mutating func reconcile(progress: TimeInterval, now: Date) -> Resolution {
        guard case .settling(let target, let deadline) = self else { return .inactive }
        let landed = progress.isFinite && abs(progress - target) <= 2.5
        guard landed || now >= deadline else { return .waiting(target) }
        self = .idle
        return .finished(target: target, landed: landed)
    }
}
