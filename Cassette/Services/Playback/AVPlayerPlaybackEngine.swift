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
        case failed(UInt64, ObjectIdentifier, PlaybackFailure)
        case timeControl(UInt64, Int)
        case stalled(UInt64)
        case seekFailed(UInt64, ObjectIdentifier, UInt64)
        case codec(UInt64, ObjectIdentifier, String)
    }
    private let lock = NSRecursiveLock()
    // Never issue a transport command synchronously from an AVFoundation KVO stack.
    private let observationQueue = DispatchQueue(label: "app.cassette.player-observations")
    private var player: AVQueuePlayer?
    private var queuedItem: AVPlayerItem?
    private var queuedURL: URL?
    private var currentURL: URL?
    private var observedID: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var statusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
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
    private var pendingSeek: (target: Double, sequence: UInt64)?
    private var executingSeek: UInt64?
    private var failedSeek = false
    private var formatInspectionTask: Task<Void, Never>?
    private var decodedCodec: String?
    private var meters: [ObjectIdentifier: NativePlaybackMeterTap] = [:]
    private var allowsAudioAnalysis = false
    private var promptStartupBuffer: TimeInterval?
    private var promptGate = PromptPlaybackGate()
    private var hasStartedPlayback = false

    var seekSequenceNumber: UInt64 { lock.withLock { seekSequence } }
    var isSeeking: Bool { lock.withLock { pendingSeek != nil || executingSeek != nil } }
    var lastSeekFailed: Bool { lock.withLock { failedSeek } }
    var isReadyForPlayback: Bool { lock.withLock { player?.currentItem?.status == .readyToPlay } }
    var playerIdentity: ObjectIdentifier? { lock.withLock { player.map(ObjectIdentifier.init) } }
    var actualCodec: String? { lock.withLock { decodedCodec } }

    /// Only reuse a progressive timeline when the target is already buffered. Otherwise a
    /// growing transcode needs a new server offset, rather than speculative HTTP Range probes.
    func canSeekInBufferedRange(to position: Double) -> Bool {
        lock.withLock {
            guard position.isFinite, position >= 0, let item = player?.currentItem,
                  item.status == .readyToPlay else { return false }
            return item.loadedTimeRanges.contains {
                let range = $0.timeRangeValue
                return position >= range.start.seconds && position < CMTimeRangeGetEnd(range).seconds - 0.1
            }
        }
    }

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

    func start(url: URL, headers: [String: String], generation: UInt64, position: Double = 0,
               paused: Bool = false, reusingPlayer: Bool = false, allowsAudioAnalysis: Bool = false,
               promptStartupBuffer: TimeInterval? = nil) {
        lock.withLock {
            let retainedPlayer = reusingPlayer ? player : nil
            stopLocked()
            self.generation = generation
            // Per-item audioMix taps force AVQueuePlayer through a separate rendering path
            // at every boundary (measured ~0.2–0.4s with continuous PCM fixtures). Keep the
            // native gapless path unmodified. Analysis remains available outside gapless mode.
            self.allowsAudioAnalysis = allowsAudioAnalysis
            self.promptStartupBuffer = promptStartupBuffer
            intendsToPlay = !paused
            let item = makeMeteredItem(url: url, headers: headers)
            let player = retainedPlayer ?? AVQueuePlayer()
            player.insert(item, after: nil)
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
            timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                self?.observationQueue.async { [weak self] in
                    guard let self else { return }
                    let isCurrent = self.lock.withLock {
                        guard self.generation == generation, self.player === player else { return false }
                        if status == .playing {
                            self.hasStartedPlayback = true
                        } else if status == .waitingToPlayAtSpecifiedRate,
                                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                                  self.hasStartedPlayback, let item = player.currentItem {
                            self.promptGate.armForRecovery(position: item.currentTime().seconds)
                            self.armPromptPlaybackLocked(item, generation: generation)
                        }
                        self.attemptPromptStartupLocked()
                        return true
                    }
                    if isCurrent { emit?(.timeControl(generation, status.rawValue)) }
                }
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
            // Preparing a next item opts into continuous playback, including when gapless
            // was enabled during an already-playing item. Never add an analysis mix here.
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
        if let item = queuedItem, player?.currentItem !== item {
            meters.removeValue(forKey: ObjectIdentifier(item))?.setActive(false)
            player?.remove(item)
        }
        queuedItem = nil
        queuedURL = nil
    }

    /// Acknowledge exactly one native handover without restarting the new item.
    func consumeQueuedTransition() -> Bool {
        lock.withLock {
            guard let item = queuedItem, player?.currentItem === item else { return false }
            currentURL = queuedURL
            queuedItem = nil; queuedURL = nil
            allowsAudioAnalysis = false
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
            failedSeek = false
            pendingSeek = nil
            executingSeek = nil
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
    func resume() { lock.withLock { intendsToPlay = true; if pendingSeek == nil && executingSeek == nil { player?.play() } } }
    func seek(to time: Double) {
        lock.withLock {
            guard time.isFinite, let player, let item = player.currentItem else { return }
            seekSequence &+= 1
            failedSeek = false
            executingSeek = nil
            // A cold range seek is a fresh buffer acquisition. Re-arm the same bounded
            // startup gate used for the first play, while keeping automatic stall waiting.
            pendingSeek = (max(0, time), seekSequence)
            hasStartedPlayback = false
            promptGate.reset(armed: supportsPromptPlayback)
            seekDeadline = Date().addingTimeInterval(12)
            player.pause()
            armPromptPlaybackLocked(item, generation: generation)
            item.cancelPendingSeeks()
            issuePendingSeekLocked()
        }
    }

    private func issuePendingSeekLocked() {
        guard let pending = pendingSeek, let player, let item = player.currentItem,
              item.status == .readyToPlay else { return }
        pendingSeek = nil
        executingSeek = pending.sequence
        let generation = generation
        item.preferredForwardBufferDuration = 0
        let local = currentURL?.isFileURL == true
        let tolerance = local ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: pending.target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak player, weak item] finished in
            guard let self, let player, let item else { return }
            self.lock.withLock {
                guard self.generation == generation, self.seekSequence == pending.sequence,
                      self.player === player, player.currentItem === item else { return }
                self.executingSeek = nil
                self.seekDeadline = .distantPast
                item.preferredForwardBufferDuration = self.forwardBuffer
                guard finished else {
                    // A failed range seek must not resume the old position or replay from zero.
                    player.pause()
                    self.failedSeek = true
                    self.handler?(.seekFailed(generation, ObjectIdentifier(item), pending.sequence))
                    return
                }
                if self.intendsToPlay {
                    player.play()
                    self.attemptPromptStartupLocked()
                } else { player.pause() }
            }
        }
    }
    func stop() { lock.withLock { stopLocked() } }
    private func stopLocked() {
        stopWatchdogLocked()
        generation &+= 1
        seekSequence &+= 1
        failedSeek = false
        pendingSeek = nil
        executingSeek = nil
        forwardBuffer = 0
        intendsToPlay = false
        allowsAudioAnalysis = false
        promptStartupBuffer = nil
        promptGate.reset(armed: false)
        hasStartedPlayback = false
        currentObservation?.invalidate(); currentObservation = nil
        timeObservation?.invalidate(); timeObservation = nil
        statusObservation?.invalidate(); statusObservation = nil
        bufferObservation?.invalidate(); bufferObservation = nil
        formatInspectionTask?.cancel(); formatInspectionTask = nil
        decodedCodec = nil
        for meter in meters.values { meter.setActive(false) }
        meters.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil; observedID = nil
        player?.pause()
        let removedItems = player?.items() ?? []
        for item in removedItems { item.cancelPendingSeeks() }
        if !removedItems.isEmpty {
            // `asset` is MainActor-isolated in the current SDK. Stop transport now,
            // then cancel loading only on these removed items, never a replacement.
            Task { @MainActor in
                for item in removedItems { item.asset.cancelLoading() }
            }
        }
        player?.removeAllItems(); player = nil
        queuedItem = nil; queuedURL = nil; currentURL = nil
        seekDeadline = .distantPast
    }
    private func observeItem(_ item: AVPlayerItem, generation: UInt64) {
        formatInspectionTask?.cancel(); formatInspectionTask = nil
        decodedCodec = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        bufferObservation?.invalidate(); bufferObservation = nil
        promptGate.reset(armed: supportsPromptPlayback && player?.timeControlStatus != .playing)
        let id = ObjectIdentifier(item)
        for (key, meter) in meters { meter.setActive(key == id) }
        // Release the completed item's tap while retaining the prebuffered next item.
        meters = meters.filter { $0.key == id || $0.key == queuedItem.map(ObjectIdentifier.init) }
        observedID = id
        hasStartedPlayback = false
        let emit = handler
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            emit?(.ended(generation, id))
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            self?.observationQueue.async { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard self.generation == generation, self.player?.currentItem === item else { return }
                    if item.status == .readyToPlay {
                        self.issuePendingSeekLocked()
                        self.inspectCodecLocked(item, generation: generation)
                        self.attemptPromptStartupLocked()
                    }
                    if item.status == .failed { emit?(.failed(generation, id, .classify(item.error, httpStatus: item.errorLog()?.events.last?.errorStatusCode))) }
                }
            }
        }
        if promptGate.isArmed {
            armPromptPlaybackLocked(item, generation: generation)
        }
    }

    private var supportsPromptPlayback: Bool {
        promptStartupBuffer != nil && currentURL?.isFileURL == false
            && currentURL?.pathExtension.lowercased() != "m3u8"
    }

    private func armPromptPlaybackLocked(_ item: AVPlayerItem, generation: UInt64) {
        guard supportsPromptPlayback, promptGate.isArmed else { return }
        if bufferObservation == nil {
            bufferObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                self?.observationQueue.async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.generation == generation, self.player?.currentItem === item else { return }
                        self.attemptPromptStartupLocked()
                    }
                }
            }
        }
        attemptPromptStartupLocked()
    }

    private func attemptPromptStartupLocked() {
        guard promptGate.isArmed, let player else { return }
        if player.timeControlStatus == .playing {
            promptGate.didStartPlaying()
            bufferObservation?.invalidate(); bufferObservation = nil
            return
        }
        guard intendsToPlay, pendingSeek == nil, executingSeek == nil,
              let url = currentURL, !url.isFileURL, url.pathExtension.lowercased() != "m3u8",
              let item = player.currentItem, item.status == .readyToPlay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay == .toMinimizeStalls,
              let startup = promptStartupBuffer else { return }
        let cushion = hasStartedPlayback ? PlaybackBufferPolicy.recoveryBuffer(startup: startup) : startup
        let remaining = item.duration.seconds - item.currentTime().seconds
        let minimum = remaining.isFinite && remaining > 0 ? min(cushion, remaining) : cushion
        guard PlaybackBufferPolicy.canStartPromptly(bufferedAhead: bufferedDuration, minimum: minimum) else { return }
        // Resume once playable audio returns, with a larger cushion after an underrun.
        // AVFoundation still waits automatically when the buffer really is empty.
        guard promptGate.consume(position: item.currentTime().seconds) else { return }
        bufferObservation?.invalidate(); bufferObservation = nil
        player.playImmediately(atRate: 1)
    }

    private func inspectCodecLocked(_ item: AVPlayerItem, generation: UInt64) {
        guard formatInspectionTask == nil else { return }
        formatInspectionTask = Task(priority: .utility) { [weak self, weak item] in
            guard let item else { return }
            do {
                let itemTracks = await MainActor.run { item.tracks.compactMap(\.assetTrack) }
                let tracks: [AVAssetTrack]
                if itemTracks.isEmpty {
                    let asset = await MainActor.run { item.asset }
                    tracks = try await asset.loadTracks(withMediaType: .audio)
                } else {
                    tracks = itemTracks.filter { $0.mediaType == .audio }
                }
                guard let track = tracks.first, !Task.isCancelled else { return }
                if #unavailable(iOS 27, macOS 27) {
                    let owner = self
                    await MainActor.run {
                        guard let owner else { return }
                        owner.lock.withLock {
                            guard owner.allowsAudioAnalysis,
                                  owner.generation == generation, owner.player?.currentItem === item,
                                  owner.currentURL?.pathExtension.lowercased() != "m3u8",
                                  owner.meters[ObjectIdentifier(item)] == nil,
                                  let meter = NativePlaybackMeterTap() else { return }
                            meter.attach(to: item, trackID: track.trackID)
                            meter.setActive(true)
                            owner.meters[ObjectIdentifier(item)] = meter
                        }
                    }
                }
                let descriptions = try await track.load(.formatDescriptions)
                guard !Task.isCancelled, let description = descriptions.first,
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      let codec = Self.codecName(format.pointee.mFormatID), let self else { return }
                self.lock.withLock {
                    guard self.generation == generation, self.player?.currentItem === item else { return }
                    self.decodedCodec = codec
                    self.handler?(.codec(generation, ObjectIdentifier(item), codec))
                }
            } catch {
                // Do not infer decoded bytes from the requested URL/codec.
                Logger.player.debug("Native format inspection unavailable: \(error.localizedDescription)")
            }
        }
    }

    private static func codecName(_ format: AudioFormatID) -> String? {
        switch format {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatAC3: "AC3"
        case kAudioFormatEnhancedAC3: "EAC3"
        default: nil
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
    private func makeMeteredItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let item = Self.makeItem(url: url, headers: headers)
        if #available(iOS 27, macOS 27, *), allowsAudioAnalysis, let meter = NativePlaybackMeterTap() {
            meters[ObjectIdentifier(item)] = meter
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.lock.withLock {
                    guard self.meters[ObjectIdentifier(item)] === meter,
                          self.player?.currentItem === item || self.queuedItem === item else { return }
                    meter.attach(to: item, trackID: AVAudioMixInputParametersTrackID.mixID.rawValue)
                }
            }
        }
        return item
    }
    private static func makeItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 0
        item.allowedAudioSpatializationFormats = .multichannel
        return item
    }
    deinit { stopLocked() }
}
