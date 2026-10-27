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
    private var storedPlayer: AudioPlayer?
    private let configuration: AudioPlayerConfiguration
    private weak var callbackDelegate: AudioPlayerDelegate?
    private var needsReplacement = false
    private var filters: [String: FilterCallback] = [:]
    private var pendingNodes: [AVAudioNode] = []
    private var storedVolume: Float = 1

    var playerIdentity: ObjectIdentifier? { playerLock.withLock { storedPlayer.map(ObjectIdentifier.init) } }

    init(configuration: AudioPlayerConfiguration = AudioStreamingPlayerEngine.defaultConfiguration) {
        self.configuration = configuration
    }

    /// Native playback and idle browsing must not allocate the fallback engine's PCM
    /// reservoir, audio graph and networking client. Configuration is retained until play.
    private func playerForPlaybackLocked() -> AudioPlayer {
        if let storedPlayer { return storedPlayer }
        let player = AudioPlayer(configuration: configuration)
        player.volume = storedVolume
        player.frameFiltering.add(entry: PlaybackBeatMeter.filterName) { buffer, _ in
            PlaybackBeatMeter.enqueue(buffer: buffer)
        }
        for (name, filter) in filters { player.frameFiltering.add(entry: name, filter: filter) }
        if !pendingNodes.isEmpty { player.attach(nodes: pendingNodes) }
        pendingNodes.removeAll()
        player.delegate = callbackDelegate
        storedPlayer = player
        needsReplacement = false
        return player
    }

    /// Engine callbacks (state changes, EOF, errors). Owned here, wired by `PlayerService`.
    var delegate: AudioPlayerDelegate? {
        get { playerLock.withLock { callbackDelegate } }
        set { playerLock.withLock {
            callbackDelegate = newValue
            if !needsReplacement { storedPlayer?.delegate = newValue }
        } }
    }

    func ownsCallbacks(from player: AudioPlayer) -> Bool {
        playerLock.withLock { !needsReplacement && storedPlayer === player }
    }

    func resetAfterMediaServicesReset() {
        playerLock.withLock {
            pendingNodes.removeAll()
            if storedPlayer != nil { replacePlayer(preserveNodes: false) }
        }
    }

    /// AudioPlayer.stop() schedules source cleanup asynchronously. Reusing that instance
    /// immediately lets its old cleanup erase the new entry, leaving every retry at zero.
    /// A stopped/failed instance is retired; queued gapless entries keep the current one.
    private func replacePlayer(preserveNodes: Bool) {
        guard let old = storedPlayer else { return }
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

    var state: AudioPlayerState { playerLock.withLock { storedPlayer?.state ?? (needsReplacement ? .stopped : .ready) } }
    var progress: Double { playerLock.withLock { storedPlayer?.progress ?? 0 } }
    var duration: Double { playerLock.withLock { storedPlayer?.duration ?? 0 } }
    var isSeekable: Bool { playerLock.withLock { storedPlayer?.isSeekable ?? false } }

    var volume: Float {
        get { playerLock.withLock { storedPlayer?.volume ?? storedVolume } }
        set { playerLock.withLock { storedVolume = newValue; storedPlayer?.volume = newValue } }
    }

    func play(url: URL, headers: [String: String]) {
        playerLock.withLock {
            if needsReplacement || storedPlayer?.state == .error { replacePlayer(preserveNodes: true) }
            playerForPlaybackLocked().play(url: url, headers: headers)
        }
    }

    func queue(url: URL, headers: [String: String]) {
        playerLock.withLock { playerForPlaybackLocked().queue(url: url, headers: headers) }
    }

    func removeFromQueue(url: URL) {
        playerLock.withLock { storedPlayer?.removeFromQueue(url: url) }
    }

    func stop() {
        playerLock.withLock {
            guard !needsReplacement else { return }
            needsReplacement = true
            storedPlayer?.delegate = nil
            storedPlayer?.stop()
        }
    }
    func pause() { playerLock.withLock { storedPlayer?.pause() } }
    func resume() { playerLock.withLock { storedPlayer?.resume() } }
    func seek(to time: Double) { playerLock.withLock { storedPlayer?.seek(to: time) } }

    func recoverQueuedTransitionIfNeeded() {
        playerLock.withLock {
            guard let player = storedPlayer else { return }
            switch player.state {
            case .paused:
                player.resume()
            case .bufferring:
                // `AudioPlayer.resume()` is deliberately a no-op unless its private state is
                // `.paused`. Wake a queued hand-off without replacing its buffered entry.
                player.pause()
                player.resume()
            default:
                break
            }
        }
    }

    // MARK: - AudioGraphHosting

    func attach(node: AVAudioNode) {
        playerLock.withLock {
            if let storedPlayer { storedPlayer.attach(node: node) }
            else if !pendingNodes.contains(where: { $0 === node }) { pendingNodes.append(node) }
        }
    }

    func addFrameFilter(named name: String, filter: @escaping FilterCallback) {
        // Replacing an existing entry keeps the "install once" behaviour the beat meter relies on.
        playerLock.withLock {
            filters[name] = filter
            storedPlayer?.frameFiltering.remove(entry: name)
            storedPlayer?.frameFiltering.add(entry: name, filter: filter)
        }
    }

    func removeFrameFilter(named name: String) {
        playerLock.withLock {
            filters[name] = nil
            storedPlayer?.frameFiltering.remove(entry: name)
        }
    }
}
