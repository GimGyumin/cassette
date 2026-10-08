import Foundation
import AVFoundation
import AudioStreaming
import OSLog

/// Owns the native queue, observations, buffering and transport. PlayerService owns queue metadata.
/// AVFoundation callbacks emit immutable events; only PlayerService decides a track/quality transition.
nonisolated final class AVPlayerPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    enum Event: Sendable {
        case itemChanged(UInt64)
        case ended(UInt64, ObjectIdentifier)
        case failed(UInt64, ObjectIdentifier)
        case timeControl(UInt64, Int)
        case stalled(UInt64)
    }
    private let lock = NSRecursiveLock()
    private var player: AVQueuePlayer?
    private var queuedItem: AVPlayerItem?
    private var queuedURL: URL?
    private var currentURL: URL?
    private var observedID: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var currentObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var watchdogID: UInt64 = 0
    private var seekDeadline = Date.distantPast
    private var handler: (@Sendable (Event) -> Void)?
    private var storedVolume: Float = 1
    private var intendsToPlay = false
    private var seekSequence: UInt64 = 0
    private var forwardBuffer: Double = 0

    var eventHandler: (@Sendable (Event) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    var state: AudioPlayerState {
        lock.withLock {
            guard let player else { return .stopped }
            if player.currentItem?.status == .failed { return .error }
            switch player.timeControlStatus {
            case .playing: return .playing
            case .waitingToPlayAtSpecifiedRate: return .bufferring
            case .paused: return .paused
            @unknown default: return .ready
            }
        }
    }
    var progress: Double { lock.withLock { Self.finite(player?.currentItem?.currentTime().seconds) } }
    var duration: Double { lock.withLock { Self.finite(player?.currentItem?.duration.seconds) } }
    var isSeekable: Bool { lock.withLock { player?.currentItem?.duration.isNumeric == true } }
    var volume: Float {
        get { lock.withLock { player?.volume ?? storedVolume } }
        set { lock.withLock { storedVolume = newValue; player?.volume = newValue } }
    }
    var hasCurrentItem: Bool { lock.withLock { player?.currentItem != nil } }
    var hasQueuedItem: Bool { lock.withLock { queuedItem != nil } }
    var observedItemID: ObjectIdentifier? { lock.withLock { observedID } }
    var timeControlStatus: AVPlayer.TimeControlStatus { lock.withLock { player?.timeControlStatus ?? .paused } }
    var bufferedDuration: Double {
        lock.withLock {
            guard let item = player?.currentItem else { return 0 }
            return PlaybackBufferPolicy.bufferedAhead(
                position: item.currentTime().seconds,
                ranges: item.loadedTimeRanges.map {
                    ($0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds)
                }
            )
        }
    }
    var isLikelyToKeepUp: Bool { lock.withLock { player?.currentItem?.isPlaybackLikelyToKeepUp ?? false } }

    func play(url: URL, headers: [String: String]) {
        start(url: url, headers: headers, generation: lock.withLock { generation &+ 1 })
    }

    func start(url: URL, headers: [String: String], generation: UInt64, position: Double = 0, paused: Bool = false) {
        lock.withLock {
            stopLocked()
            self.generation = generation
            intendsToPlay = !paused
            let item = Self.makeItem(url: url, headers: headers)
            let player = AVQueuePlayer(items: [item])
            player.allowsExternalPlayback = true
            player.automaticallyWaitsToMinimizeStalling = true
            player.volume = storedVolume
            #if os(iOS)
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            #endif
            self.player = player
            currentURL = url
            observeItem(item, generation: generation)
            let emit = handler
            currentObservation = player.observe(\.currentItem, options: [.new]) { _, _ in emit?(.itemChanged(generation)) }
            timeObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                emit?(.timeControl(generation, player.timeControlStatus.rawValue))
            }
            if position > 0 {
                seek(to: position)
            } else if !paused { player.play() }
        }
    }

    @discardableResult func prepareNext(url: URL, headers: [String: String]) -> Bool {
        lock.withLock {
            guard let player, player.currentItem != nil else { return false }
            cancelQueuedItemLocked()
            let item = Self.makeItem(url: url, headers: headers)
            item.preferredForwardBufferDuration = 5
            guard player.canInsert(item, after: player.currentItem) else { return false }
            queuedItem = item
            queuedURL = url
            player.insert(item, after: player.currentItem)
            return true
        }
    }
    func queue(url: URL, headers: [String: String]) { prepareNext(url: url, headers: headers) }
    func removeFromQueue(url: URL) { lock.withLock { if queuedURL == url { cancelQueuedItemLocked() } } }
    func cancelQueuedItem() { lock.withLock { cancelQueuedItemLocked() } }
    private func cancelQueuedItemLocked() {
        if let item = queuedItem, player?.currentItem !== item { player?.remove(item) }
        queuedItem = nil
        queuedURL = nil
    }

    /// Acknowledge exactly one native handover without restarting the new item.
    func consumeQueuedTransition() -> Bool {
        lock.withLock {
            guard let item = queuedItem, player?.currentItem === item else { return false }
            currentURL = queuedURL
            queuedItem = nil; queuedURL = nil
            observeItem(item, generation: generation)
            return true
        }
    }

    /// Manual next uses the already buffered item, just like a natural handover.
    /// A stale URL must not consume a different queued track.
    func advanceToPreparedNext(expectedURL: URL) -> Bool {
        lock.withLock {
            guard let player, let item = queuedItem, queuedURL == expectedURL,
                  item.status != .failed else { return false }
            if player.currentItem !== item {
                guard player.items().contains(where: { $0 === item }) else { return false }
                player.advanceToNextItem()
            }
            guard player.currentItem === item else { return false }
            seekSequence &+= 1
            seekDeadline = .distantPast
            intendsToPlay = true
            player.play()
            return true
        }
    }
    func setForwardBuffer(_ seconds: Double) {
        lock.withLock {
            forwardBuffer = seconds
            player?.currentItem?.preferredForwardBufferDuration = seconds
        }
    }
    func pause() { lock.withLock { intendsToPlay = false; stopWatchdogLocked(); player?.pause() } }
    func resume() { lock.withLock { intendsToPlay = true; player?.play() } }
    func seek(to time: Double) {
        lock.withLock {
            guard time.isFinite, let player, let item = player.currentItem else { return }
            seekSequence &+= 1
            let sequence = seekSequence
            let generation = generation
            seekDeadline = Date().addingTimeInterval(12)
            item.cancelPendingSeeks()
            item.preferredForwardBufferDuration = 0
            let local = currentURL?.isFileURL == true
            let tolerance = local ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
            player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak player, weak item] finished in
                // An unsupported range seek can finish with `false`. The current
                // request still owns transport intent and must release startup;
                // sequence/item checks below exclude cancelled, superseded seeks.
                guard let self, let player, let item else { return }
                self.lock.withLock {
                    guard self.generation == generation, self.seekSequence == sequence,
                          self.player === player, player.currentItem === item else { return }
                    if !finished {
                        Logger.player.warning("[SEEK] AVPlayer could not complete the requested seek; restoring transport intent")
                    }
                    self.seekDeadline = .distantPast
                    item.preferredForwardBufferDuration = self.forwardBuffer
                    if self.intendsToPlay { player.play() } else { player.pause() }
                }
            }
        }
    }
    func stop() { lock.withLock { stopLocked() } }
    private func stopLocked() {
        stopWatchdogLocked()
        generation &+= 1
        seekSequence &+= 1
        forwardBuffer = 0
        intendsToPlay = false
        currentObservation?.invalidate(); currentObservation = nil
        timeObservation?.invalidate(); timeObservation = nil
        statusObservation?.invalidate(); statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil; observedID = nil
        player?.pause(); player?.removeAllItems(); player = nil
        queuedItem = nil; queuedURL = nil; currentURL = nil
        seekDeadline = .distantPast
    }
    private func observeItem(_ item: AVPlayerItem, generation: UInt64) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        let id = ObjectIdentifier(item)
        observedID = id
        let emit = handler
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            emit?(.ended(generation, id))
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { emit?(.failed(generation, id)) }
        }
    }
    func startWatchdog(generation: UInt64) {
        lock.withLock {
            guard watchdog == nil, generation == self.generation else { return }
            watchdogID &+= 1
            let id = watchdogID
            watchdog = Task { [weak self] in
                var monitor = PlaybackStallMonitor()
                defer { self?.finishWatchdog(id: id) }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    let sample = self.lock.withLock { () -> (Double, Bool, Bool)? in
                        guard generation == self.generation, id == self.watchdogID,
                              let player = self.player, let item = player.currentItem,
                              player.timeControlStatus != .paused else { return nil }
                        return (item.currentTime().seconds,
                                !item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferEmpty || player.reasonForWaitingToPlay != nil,
                                Date() < self.seekDeadline)
                    }
                    guard let sample else { return }
                    if monitor.observe(mediaTime: sample.0, now: ProcessInfo.processInfo.systemUptime, cannotPlay: sample.1, isSeeking: sample.2) {
                        self.eventHandler?(.stalled(generation))
                        monitor = PlaybackStallMonitor()
                    }
                }
            }
        }
    }
    func stopWatchdog() { lock.withLock { stopWatchdogLocked() } }
    private func stopWatchdogLocked() { watchdogID &+= 1; watchdog?.cancel(); watchdog = nil }
    private func finishWatchdog(id: UInt64) { lock.withLock { if watchdogID == id { watchdog = nil } } }
    private static func finite(_ seconds: Double?) -> Double { seconds?.isFinite == true ? max(0, seconds!) : 0 }
    private static func makeItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 0
        item.allowedAudioSpatializationFormats = .multichannel
        return item
    }
    deinit { stopLocked() }
}
