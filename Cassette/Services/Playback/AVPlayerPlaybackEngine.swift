import Foundation
import AVFoundation
import AudioStreaming

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
        lock.withLock { player?.currentItem?.loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.max() ?? 0 }
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
            if position > 1 {
                seekDeadline = Date().addingTimeInterval(12)
                player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                    guard let self, let player else { return }
                    self.lock.withLock {
                        // A late seek completion must never restart an outgoing player after stop/skip.
                        guard self.generation == generation, self.player === player else { return }
                        // Honor play/pause input received while the restore seek was still pending.
                        if self.intendsToPlay { player.play() } else { player.pause() }
                    }
                }
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
    func setForwardBuffer(_ seconds: Double) { lock.withLock { player?.currentItem?.preferredForwardBufferDuration = seconds } }
    func pause() { lock.withLock { intendsToPlay = false; stopWatchdogLocked(); player?.pause() } }
    func resume() { lock.withLock { intendsToPlay = true; player?.play() } }
    func seek(to time: Double) {
        lock.withLock {
            seekDeadline = Date().addingTimeInterval(12)
            let local = currentURL?.isFileURL == true
            let tolerance = local ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
            player?.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }
    func stop() { lock.withLock { stopLocked() } }
    private func stopLocked() {
        stopWatchdogLocked()
        generation &+= 1
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
