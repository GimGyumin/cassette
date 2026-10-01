// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AudioStreaming
import Foundation
import OSLog

/// Bridges `AudioPlayerDelegate` callbacks (dispatched on main via `asyncOnMain`)
/// to `PlayerService`, which is an actor and therefore cannot conform directly.
///
/// Kept out of `PlayerService.swift` on purpose: the delegate is the only type in
/// that file with no access to the actor's private state, so it is the safe seam
/// for the ongoing PlayerService decomposition (see `docs/ARCHITECTURE.md`).
final class AudioStreamingDelegate: AudioPlayerDelegate, @unchecked Sendable {
    weak var service: PlayerService?

    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {
        // The engine tells us which entry it actually started: the end-of-track watchdog needs
        // this to distinguish a completed gapless transition from a stalled one.
        guard let service else { return }
        let identifier = entryId.id
        Task { await service.handleEngineStartedEntry(entryIdentifier: identifier) }
    }

    func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}

    func audioPlayerStateChanged(
        player: AudioPlayer,
        with newState: AudioPlayerState,
        previous: AudioPlayerState
    ) {
        // [DIAG] Correlate with [NET-COVER] logs: underrun while cover fetches are in flight
        // confirms bandwidth starvation; underrun with no concurrent covers points elsewhere.
        if newState == .bufferring && previous == .playing {
            Logger.player.warning("[NET-AUDIO] buffer underrun — state: playing → bufferring")
            if let service {
                Task { await service.handleBufferUnderrun() }
            }
        }
        guard let service else { return }
        Task { await service.handleAudioStateChanged(newState) }
    }

    func audioPlayerDidFinishPlaying(
        player: AudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    ) {
        // Only natural completions (eof) trigger end-of-track handling.
        // User-initiated play() or stop() arrive with .userAction / .none.
        guard let service, stopReason == .eof else { return }
        let finishedEntryIdentifier = entryId.id
        Task {
            await service.handleEndOfTrack(
                engineConfirmed: true,
                finishedEntryIdentifier: finishedEntryIdentifier
            )
        }
    }

    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
        guard let service else { return }
        Task { await service.handleAudioError(error) }
    }

    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}

    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
