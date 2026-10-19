import Foundation
import OSLog
import AudioStreaming

extension PlayerService {
    func commitSeek(target: Double, reopensSource: Bool, epoch: UInt64, request: UInt64,
                    intendsToPlay: Bool) async {
        guard !Task.isCancelled, epoch == playbackEpoch, request == seekRequestGeneration else { return }
        seekCommitTask = nil
        seekNeedsCommit = false
        if let source = currentSource, reopensSource {
            playbackAcquisitionTask?.cancel()
            playbackAcquisitionTask = nil
            cancelPendingCacheDownload()
            cancelPendingPrefetch()
            pendingRestoreInfo = (seekTime: target, pause: !intendsToPlay)
            startEnginePlayback(url: source.url, headers: source.customHeaders, useSystemPlayer: true,
                                reusingSystemPlayer: true)
        } else {
            seekEngine(to: target)
        }
        if intendsToPlay { startProgressTimer() }
        scheduleSeekSettlement(target: target, epoch: epoch, request: request)
    }

    /// Runs even while paused; a failed/cold seek must not depend on the playback progress timer.
    func scheduleSeekSettlement(target: Double, epoch: UInt64, request: UInt64) {
        seekSettlementTask?.cancel()
        seekSettlementTask = Task { [weak self] in
            await self?.monitorSeekSettlement(target: target, epoch: epoch, request: request)
        }
    }

    private func monitorSeekSettlement(target: Double, epoch: UInt64, request: UInt64) async {
        let deadline = Date().addingTimeInterval(30)
        while !Task.isCancelled, epoch == playbackEpoch, request == seekRequestGeneration,
              seekState.target == target {
            if seekDownloadTask != nil { return } // The cancellable download owns its resource timeout.
            let playback = await MainActor.run { (!state.playbackState.hasPlaybackIntent, state.currentTrack?.id) }
            let paused = playback.0
            guard !Task.isCancelled, epoch == playbackEpoch, request == seekRequestGeneration else { return }
            let ready = !systemPlayback.isActive || systemEngine.isReadyForPlayback
            if ready {
                let progress = engineProgress()
                _ = reconcilePendingSeek(engineProgress: progress, allowsPausedOffset: paused)
                if seekState == .idle {
                    systemPlayback.seekSettleDeadline = .distantPast
                    if !paused, activeEngine.state == .playing {
                        // Position, pending clock and .playing are one UI transaction.
                        await publishEnginePlaybackConfirmation(settledPosition: progress)
                    } else {
                        await MainActor.run {
                            guard !Task.isCancelled, state.currentTrack?.id == playback.1 else { return }
                            state.position = min(progress, state.duration)
                            state.pendingSeekPosition = nil
                        }
                    }
                    guard !Task.isCancelled, epoch == playbackEpoch, request == seekRequestGeneration else { return }
                    await pushPositionSnapshot(rate: paused ? 0 : nil)
                    return
                }
            }
            if Date() >= deadline {
                await recoverFailedSeek(target: target)
                return
            }
            // Fast local seeks settle without a half-second UI-clock gap. Slow/remote seeks
            // retain the lower-frequency poll; this loop runs only during an actual request.
            let fastLocal = currentSource?.isLocal == true && Date() < deadline.addingTimeInterval(-29)
            do { try await Task.sleep(for: fastLocal ? .milliseconds(33) : .milliseconds(100)) } catch { return }
        }
    }

    /// Servers without working byte ranges need a complete response before native file seeking.
    /// This buffer is temporary, not a permanent download or a change to the cache preference.
    func recoverFailedSeek(target: Double, failedGeneration: UInt64? = nil) async {
        guard !Task.isCancelled, seekDownloadTask == nil,
              seekRecoveryInFlight != seekRequestGeneration,
              failedGeneration == nil || failedGeneration == systemPlayback.generation,
              let source = currentSource, seekState.target == target else { return }
        let epoch = playbackEpoch
        let request = seekRequestGeneration
        seekRecoveryInFlight = request
        defer { if seekRecoveryInFlight == request { seekRecoveryInFlight = nil } }
        if seekRecoveryRequest == request {
            await failSeek(target: target, epoch: epoch, request: request)
            return
        }
        seekRecoveryRequest = request
        let playback = await MainActor.run { (state.playbackState.hasPlaybackIntent, state.currentTrack?.audioFormat) }
        guard epoch == playbackEpoch, request == seekRequestGeneration, seekState.target == target else { return }
        guard !source.isLocal, seekBufferURL == nil else {
            await failSeek(target: target, epoch: epoch, request: request)
            return
        }
        if source.supportsTranscodeOffset || source.url.pathExtension.lowercased() == "m3u8" {
            // One time-based/HLS retry, keeping codec, session identifiers and playback intent.
            seekState = .settling(target: target, deadline: Date().addingTimeInterval(30))
            pendingRestoreInfo = (seekTime: target, pause: !playback.0)
            startEnginePlayback(url: source.url, headers: source.customHeaders, useSystemPlayer: true,
                                reusingSystemPlayer: true)
            scheduleSeekSettlement(target: target, epoch: epoch, request: request)
            if playback.0 { startProgressTimer() }
            return
        }
        stopProgressTimer()
        pendingRestoreInfo = (seekTime: target, pause: !playback.0)
        tearDownSystemPlayer()
        seekState = .settling(target: target, deadline: Date().addingTimeInterval(600))
        guard await commitPresentation(playbackContext, { state in
            state.position = target
            if playback.0 { state.playbackState = .recovering }
            return true
        }) else { return }
        guard epoch == playbackEpoch, request == seekRequestGeneration else { return }
        seekDownloadTask = Task { [weak self] in
            await self?.downloadSeekBuffer(source: source, target: target, epoch: epoch,
                                          request: request, intendsToPlay: playback.0,
                                          originalSuffix: playback.1?.lowercased())
        }
    }

    private func downloadSeekBuffer(source: MediaSource, target: Double, epoch: UInt64,
                                    request: UInt64, intendsToPlay: Bool, originalSuffix: String?) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            var downloadRequest = URLRequest(url: source.url)
            for (name, value) in source.customHeaders { downloadRequest.setValue(value, forHTTPHeaderField: name) }
            downloadRequest.setValue(nil, forHTTPHeaderField: "Range")
            let (temporary, response) = try await session.download(for: downloadRequest)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CassetteError.seekUnavailable
            }
            try restoreSeekFromBuffer(temporary: temporary, response: response, target: target,
                                      epoch: epoch, request: request, intendsToPlay: intendsToPlay,
                                      originalSuffix: originalSuffix)
        } catch {
            guard !Task.isCancelled, epoch == playbackEpoch, request == seekRequestGeneration else { return }
            seekDownloadTask = nil
            await failSeek(target: target, epoch: epoch, request: request)
        }
    }

    /// Commit only the response owned by the latest scrub, then restore native file playback.
    func restoreSeekFromBuffer(temporary: URL, response: URLResponse, target: Double, epoch: UInt64,
                               request: UInt64, intendsToPlay: Bool, originalSuffix: String?) throws {
        guard epoch == playbackEpoch, request == seekRequestGeneration, seekState.target == target else { return }
        try AudioResponseValidator.validate(fileAt: temporary, response: response,
            songId: "seek-buffer", logger: Logger.player)
        let suffix = CacheFormat.flacOriginal.downloadFileExtension(mimeType: response.mimeType,
            originalSuffix: originalSuffix)
        let buffered = FileManager.default.temporaryDirectory
            .appendingPathComponent("cassette-seek-\(UUID().uuidString).\(suffix)")
        try FileManager.default.moveItem(at: temporary, to: buffered)
        seekBufferURL = buffered
        seekDownloadTask = nil
        pendingRestoreInfo = (seekTime: target, pause: !intendsToPlay)
        // Keep source provenance, but let AVPlayer seek the complete local response.
        startEnginePlayback(url: buffered, headers: [:], useSystemPlayer: true, reusingSystemPlayer: true)
        seekState = .settling(target: target, deadline: Date().addingTimeInterval(30))
        scheduleSeekSettlement(target: target, epoch: epoch, request: request)
        if intendsToPlay { startProgressTimer() }
    }

    private func failSeek(target: Double, epoch: UInt64, request: UInt64) async {
        guard epoch == playbackEpoch, request == seekRequestGeneration else { return }
        let context = playbackContext
        seekState = .idle
        seekNeedsCommit = false
        await finishPlaybackFailure(.seekUnavailable, context: context, position: target)
    }
}
