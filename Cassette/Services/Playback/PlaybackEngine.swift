// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import AudioStreaming

/// Transport surface of the audio engine.
///
/// `PlayerService` stays the single owner of playback state, but the engine under it must be
/// replaceable: a fake engine makes queue, transition and session logic testable without audio
/// hardware, and it is the seam the `PlayerService` decomposition needs
/// (see `docs/ARCHITECTURE.md` → *Known debt*).
///
/// Every member is 1:1 with what `AudioPlayer` already exposes, so adopting it changes no
/// behaviour — it only moves the concrete engine behind a protocol.
nonisolated protocol PlaybackEngine: AnyObject, Sendable {
    var state: AudioPlayerState { get }
    var progress: Double { get }
    var duration: Double { get }
    var isSeekable: Bool { get }
    var volume: Float { get set }

    /// Starts the given entry, replacing anything already playing.
    func play(url: URL, headers: [String: String])
    /// Hands the engine the next entry so it pre-buffers it (gapless / pre-queue).
    func queue(url: URL, headers: [String: String])
    func removeFromQueue(url: URL)
    func stop()
    func pause()
    func resume()
    func seek(to time: Double)

}

/// Adapter-specific callback bridge; native AVPlayer does not pretend to own an AudioPlayer.
nonisolated protocol AudioStreamingPlaybackEngine: PlaybackEngine {
    /// Engine callbacks (state changes, EOF, errors). Owned by the engine, wired once by
    /// `PlayerService`; a fake engine can drive them to simulate a transition in tests.
    var delegate: AudioPlayerDelegate? { get set }

    /// AudioStreaming announces a queued entry when it selects it, before decoded audio is
    /// necessarily moving. If that hand-off parks in `waitingForData`, wake the transport without
    /// replacing the already-buffered entry.
    func recoverQueuedTransitionIfNeeded()
}

/// The AVFoundation graph the app inserts nodes into — the ReplayGain EQ unit and the beat tap.
///
/// Kept apart from `PlaybackEngine` on purpose: a fake transport must not have to pretend it owns an
/// audio graph, and these two call sites are the only places that need the concrete engine type.
nonisolated protocol AudioGraphHosting: AnyObject, Sendable {
    func attach(node: AVAudioNode)
    func addFrameFilter(named name: String, filter: @escaping FilterCallback)
    func removeFrameFilter(named name: String)
}
