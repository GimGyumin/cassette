// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import AudioStreaming

/// `PlaybackEngine` backed by the AudioStreaming `AudioPlayer`.
///
/// Pure forwarding: the wrapper exists so `PlayerService` depends on the protocol instead of the
/// concrete engine, which is what makes the queue/transition logic testable. It also owns the buffer
/// tuning, so a test (or a future adaptive-buffer path) can construct an engine with different
/// values without touching `PlayerService`.
nonisolated final class AudioStreamingPlayerEngine: AudioStreamingPlaybackEngine, AudioGraphHosting, @unchecked Sendable {

    /// Start with two seconds of decoded audio, then continue filling the 30-second reservoir.
    /// A real underrun requires five seconds before resuming, keeping fast startup separate
    /// from recovery hysteresis. These are decoded durations, not wall-clock latency promises.
    nonisolated static let defaultConfiguration = AudioPlayerConfiguration(
        flushQueueOnSeek: true,
        bufferSizeInSeconds: 30,
        secondsRequiredToStartPlaying: 2,
        gracePeriodAfterSeekInSeconds: 1,
        secondsRequiredToStartPlayingAfterBufferUnderrun: 5,
        enableLogs: false
    )

    private let player: AudioPlayer

    init(configuration: AudioPlayerConfiguration = AudioStreamingPlayerEngine.defaultConfiguration) {
        self.player = AudioPlayer(configuration: configuration)
    }

    /// Engine callbacks (state changes, EOF, errors). Owned here, wired by `PlayerService`.
    var delegate: AudioPlayerDelegate? {
        get { player.delegate }
        set { player.delegate = newValue }
    }

    // MARK: - PlaybackEngine

    var state: AudioPlayerState { player.state }
    var progress: Double { player.progress }
    var duration: Double { player.duration }
    var isSeekable: Bool { player.isSeekable }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play(url: URL, headers: [String: String]) {
        player.play(url: url, headers: headers)
    }

    func queue(url: URL, headers: [String: String]) {
        player.queue(url: url, headers: headers)
    }

    func removeFromQueue(url: URL) {
        player.removeFromQueue(url: url)
    }

    func stop() { player.stop() }
    func pause() { player.pause() }
    func resume() { player.resume() }
    func seek(to time: Double) { player.seek(to: time) }

    func recoverQueuedTransitionIfNeeded() {
        switch player.state {
        case .paused:
            player.resume()
        case .bufferring:
            // `AudioPlayer.resume()` is deliberately a no-op unless its private state is
            // `.paused`. A queued hand-off can instead be left in `.waitingForData` (published as
            // `.bufferring`), so reproduce the transport reset that previously only happened
            // after the listener touched play/pause.
            player.pause()
            player.resume()
        default:
            break
        }
    }

    // MARK: - AudioGraphHosting

    func attach(node: AVAudioNode) {
        player.attach(node: node)
    }

    func addFrameFilter(named name: String, filter: @escaping FilterCallback) {
        // Replacing an existing entry keeps the "install once" behaviour the beat meter relies on.
        player.frameFiltering.remove(entry: name)
        player.frameFiltering.add(entry: name, filter: filter)
    }

    func removeFrameFilter(named name: String) {
        player.frameFiltering.remove(entry: name)
    }
}
