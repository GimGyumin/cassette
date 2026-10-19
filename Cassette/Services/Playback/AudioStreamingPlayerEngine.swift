// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AVFoundation
import AudioStreaming

/// `PlaybackEngine` backed by the AudioStreaming `AudioPlayer`.
///
/// Owns buffer tuning and the dependency's lifetime. A stopped instance is retired before
/// the next explicit play so asynchronous cleanup cannot erase a new track's queue.
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

    private let playerLock = NSRecursiveLock()
    private var storedPlayer: AudioPlayer
    private var player: AudioPlayer { playerLock.withLock { storedPlayer } }
    private let configuration: AudioPlayerConfiguration
    private weak var callbackDelegate: AudioPlayerDelegate?
    private var needsReplacement = false
    private var filters: [String: FilterCallback] = [:]

    var playerIdentity: ObjectIdentifier { playerLock.withLock { ObjectIdentifier(storedPlayer) } }

    init(configuration: AudioPlayerConfiguration = AudioStreamingPlayerEngine.defaultConfiguration) {
        self.configuration = configuration
        self.storedPlayer = AudioPlayer(configuration: configuration)
        player.frameFiltering.add(entry: PlaybackBeatMeter.filterName) { buffer, _ in
            PlaybackBeatMeter.enqueue(buffer: buffer)
        }
    }

    /// Engine callbacks (state changes, EOF, errors). Owned here, wired by `PlayerService`.
    var delegate: AudioPlayerDelegate? {
        get { playerLock.withLock { callbackDelegate } }
        set { playerLock.withLock {
            callbackDelegate = newValue
            if !needsReplacement { storedPlayer.delegate = newValue }
        } }
    }

    func ownsCallbacks(from player: AudioPlayer) -> Bool {
        playerLock.withLock { !needsReplacement && storedPlayer === player }
    }

    func resetAfterMediaServicesReset() {
        playerLock.withLock { replacePlayer(preserveNodes: false) }
    }

    /// AudioPlayer.stop() schedules source cleanup asynchronously. Reusing that instance
    /// immediately lets its old cleanup erase the new entry, leaving every retry at zero.
    /// A stopped/failed instance is retired; queued gapless entries keep the current one.
    private func replacePlayer(preserveNodes: Bool) {
        let old = storedPlayer
        old.delegate = nil
        let volume = old.volume
        old.stop()
        let nodes = preserveNodes ? old.customAttachedNodes : []
        for node in nodes { old.detach(node: node) }
        old.frameFiltering.remove(entry: PlaybackBeatMeter.filterName)
        let replacement = AudioPlayer(configuration: configuration)
        replacement.volume = volume
        replacement.frameFiltering.add(entry: PlaybackBeatMeter.filterName) { buffer, _ in
            PlaybackBeatMeter.enqueue(buffer: buffer)
        }
        for (name, filter) in filters { replacement.frameFiltering.add(entry: name, filter: filter) }
        if !nodes.isEmpty { replacement.attach(nodes: nodes) }
        replacement.delegate = callbackDelegate
        storedPlayer = replacement
        needsReplacement = false
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
        playerLock.withLock {
            if needsReplacement || storedPlayer.state == .error { replacePlayer(preserveNodes: true) }
            storedPlayer.play(url: url, headers: headers)
        }
    }

    func queue(url: URL, headers: [String: String]) {
        player.queue(url: url, headers: headers)
    }

    func removeFromQueue(url: URL) {
        player.removeFromQueue(url: url)
    }

    func stop() {
        playerLock.withLock {
            guard !needsReplacement else { return }
            needsReplacement = true
            storedPlayer.delegate = nil
            storedPlayer.stop()
        }
    }
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
        playerLock.withLock { storedPlayer.attach(node: node) }
    }

    func addFrameFilter(named name: String, filter: @escaping FilterCallback) {
        // Replacing an existing entry keeps the "install once" behaviour the beat meter relies on.
        playerLock.withLock {
            filters[name] = filter
            storedPlayer.frameFiltering.remove(entry: name)
            storedPlayer.frameFiltering.add(entry: name, filter: filter)
        }
    }

    func removeFrameFilter(named name: String) {
        playerLock.withLock {
            filters[name] = nil
            storedPlayer.frameFiltering.remove(entry: name)
        }
    }
}
