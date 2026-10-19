// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

// Actor-isolated implementation; PlayerService remains the single playback owner.
extension PlayerService {
    // MARK: - Progress timer

    func scheduleAutomaticDownload(song: DisplayableSong, serverId: UUID) async {
        if AtmosVariantCatalogue.isAtmos(song),
           await MainActor.run(body: { streamingSettings.downloadFormat.subsonicMaxBitRate != nil }) { return }
        guard CassettePerformance.budget.allowsAutomaticMediaDownloads else { return }
        guard UserDefaults.standard.bool(forKey: Self.automaticDownloadUserDefaultsKey) else { return }
        let (isLimited, allowCellular) = await MainActor.run {
            (
                serverService.state.isLimitedNetwork,
                UserDefaults.standard.bool(forKey: Self.automaticDownloadOverCellularUserDefaultsKey)
            )
        }
        guard Self.shouldAllowAutomaticDownload(
            isLimited: isLimited,
            allowCellular: allowCellular
        ) else {
            Logger.download.debug("Automatic download skipped — cellular use is disabled")
            return
        }
        let key = "\(serverId.uuidString):\(song.id)"
        let requestKey = await MainActor.run {
            let revision = (try? serverService.state.requestIdentity(for: serverId).revision) ?? 0
            return "\(key):\(revision):\(streamingSettings.downloadFormat.rawValue)"
        }
        guard automaticDownloadRetry.permits(requestKey) else { return }
        guard automaticDownloadTasks.insert(key).inserted else { return }
        Task {
            defer { automaticDownloadTasks.remove(key) }
            let scheduledAt = Date()
            // A second full-file request beside a stream that is still opening can starve the
            // foreground request, especially for lossless originals. Wait until the media clock
            // proves that this exact track is producing audio before sharing the connection.
            guard await waitForEstablishedPlayback(of: song.id) else { return }
            if isLimited {
                // Preserve the existing 45-second limited-network grace period, counting time
                // already spent establishing playback.
                let remaining = max(0, 45 - Date().timeIntervalSince(scheduledAt))
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                let stillPlayingThisTrack = await MainActor.run {
                    state.playbackState == .playing && (state.currentPlaybackTrack?.id ?? state.currentTrack?.id) == song.id
                }
                guard stillPlayingThisTrack else { return }
            }
            guard CassettePerformance.budget.allowsAutomaticMediaDownloads,
                  await MainActor.run(body: {
                let automaticDownloadsEnabled = UserDefaults.standard.bool(
                    forKey: Self.automaticDownloadUserDefaultsKey
                )
                let cellularAllowed = UserDefaults.standard.bool(
                    forKey: Self.automaticDownloadOverCellularUserDefaultsKey
                )
                return automaticDownloadsEnabled
                    && serverService.state.isOnline
                    && serverService.state.activeServer?.id == serverId
                    && Self.shouldAllowAutomaticDownload(
                        isLimited: serverService.state.isLimitedNetwork,
                        allowCellular: cellularAllowed
                    )
            }), !(await downloadService.isDownloaded(songId: song.id, serverId: serverId)) else { return }
            do {
                let downloadableSong = await MainActor.run { song.asSong() }
                try await downloadService.download(song: downloadableSong, serverId: serverId)
                automaticDownloadRetry.succeeded(requestKey)
                // Normally playback is already healthy, so this is a no-op. If the engine fell
                // back into acquisition while the transfer finished, immediately use the valid
                // local file instead of continuing to wait on the remote response.
                let visibleSong = await MainActor.run {
                    (state.currentPlaybackTrack?.id ?? state.currentTrack?.id) == song.id ? state.currentTrack : nil
                }
                if let visibleSong { _ = await recoverAcquiringPlaybackFromLocalMedia(
                    song: visibleSong,
                    serverId: serverId,
                    expectedEpoch: nil,
                    reason: "automatic download completed"
                ) }
            } catch {
                if Task.isCancelled || PlaybackFailure.classify(error).kind == .cancelled { return }
                automaticDownloadRetry.failed(requestKey, error: error)
                Logger.download.error("Automatic download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
            }
        }
    }

    /// Waits for a real advancing media clock rather than trusting an optimistic `.playing`
    /// callback. This keeps a background full-file transfer off the playback critical path.
    private func waitForEstablishedPlayback(of songID: String) async -> Bool {
        var stability = PlaybackPreparationStability()
        for _ in 0..<80 {
            guard !Task.isCancelled else { return false }
            let snapshot = await MainActor.run {
                (state.currentPlaybackTrack?.id ?? state.currentTrack?.id, state.playbackState)
            }
            guard snapshot.0 == songID else { return false }
            if stability.observe(mediaTime: engineProgress(), now: ProcessInfo.processInfo.systemUptime,
                                 isPlaying: snapshot.1 == .playing, requiredDuration: 5),
               !systemPlayback.isActive || currentSource?.isLocal == true || systemEngine.bufferedDuration >= 10 {
                return true
            }
            if snapshot.1 == .paused || snapshot.1 == .idle {
                return false
            }
            if case .error = snapshot.1 { return false }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }

    /// An automatic download may proceed when the network is unmetered/unconstrained, or when
    /// the user explicitly allowed downloads over a limited connection.
    nonisolated static func shouldAllowAutomaticDownload(
        isLimited: Bool,
        allowCellular: Bool
    ) -> Bool {
        !isLimited || allowCellular
    }

    /// Also covers enabling the setting during playback and retrying after connectivity returns.
    private func checkAutomaticDownload() async {
        guard Date() >= automaticDownloadCheckDate else { return }
        automaticDownloadCheckDate = Date().addingTimeInterval(30)
        let current = await MainActor.run { () -> (DisplayableSong, UUID)? in
            guard state.playbackState == .playing, !state.isLiveStream,
                  let song = state.currentTrack, let serverId = serverService.state.activeServer?.id else { return nil }
            return (song, serverId)
        }
        if let (song, serverId) = current {
            await scheduleAutomaticDownload(song: currentSource?.playbackSong ?? song, serverId: serverId)
        }
    }

    func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = CassettePerformance.budget.playbackProgressInterval
                do { try await Task.sleep(for: interval, tolerance: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, let self else { break }
                await self.handleSystemPlayerItemChanged(generation: self.systemPlayback.generation)
                let epoch = await self.playbackEpoch
                let trackID = await MainActor.run { self.state.currentTrack?.id }
                let progress = await self.engineProgress()
                let audioDuration = await self.engineDuration()
                let engineSeekable = await self.engineIsSeekable()
                // Read once per tick: a hand-over may start or finish while this pass awaits.
                let isHandingOver = await self.isTrackTransitionPending
                guard !isHandingOver, epoch == (await self.playbackEpoch) else { continue }
                let positionBeforeTick = await MainActor.run { self.state.position }
                let seekState = await self.reconcilePendingSeek(engineProgress: progress)
                let engineIsEstimate = await self.durationIsEstimate()
                let preservesCatalog = await self.preservesCatalogDuration()
                guard epoch == (await self.playbackEpoch), !Task.isCancelled else { continue }
                if !seekState.isSettling, seekState.target != nil {
                    // The progress loop can win settlement before the dedicated monitor.
                    // It must publish the same atomic UI completion, rather than clear the
                    // hint first and leave .recovering until some future clock increment.
                    let producingAudio = await self.activeEngine.state == .playing
                    await self.publishEnginePlaybackConfirmation(settledPosition: progress,
                                                                 confirmsPlayback: producingAudio)
                }
                // A stream reconnect can reset its clock without ending the song. Recover
                // before publishing zero, so neither the UI nor repeat-one treats it as EOF.
                if !seekState.isSettling,
                   await self.recoverUnexpectedProgressReset(progress: progress) { continue }
                await MainActor.run {
                    guard !Task.isCancelled, !isHandingOver, self.state.currentTrack?.id == trackID else { return }
                    let cur = self.state.isLiveStream ? 0 : PlaybackDurationPolicy.resolve(
                        catalog: self.state.currentTrack?.duration ?? 0,
                        engine: audioDuration,
                        engineIsEstimate: engineIsEstimate,
                        preserveCatalog: preservesCatalog
                    )
                    if abs(self.state.duration - cur) > 0.5 || !self.state.duration.isFinite {
                        self.state.duration = cur
                    }
                    if !seekState.isSettling, self.state.pendingSeekPosition == nil {
                        let clamped = cur > 0 ? min(progress, cur) : progress
                        if self.state.position != clamped {
                            self.state.position = clamped
                        }
                    }
                    let canSeek = engineSeekable || (audioDuration <= 0 && cur > 0)
                    if self.state.isSeekable != canSeek {
                        self.state.isSeekable = canSeek
                    }
                }
                guard epoch == (await self.playbackEpoch), !Task.isCancelled, !isHandingOver else { continue }
                // Advancing media time confirms audio after startup, buffering or recovery.
                // A seek clock jump is excluded until the seek has settled.
                if !seekState.isSettling, progress > positionBeforeTick + 0.05 {
                    await self.publishEnginePlaybackConfirmation()
                }
                if !seekState.isSettling {
                    await self.checkEndOfTrackFallback(progress: progress)
                }
                guard epoch == (await self.playbackEpoch), !Task.isCancelled else { continue }
                await self.checkSustainedPlaybackStall(progress: progress)
                await self.ensureGaplessPreparation()
                let publishedProgress = seekState.isSettling
                    ? (seekState.target ?? progress)
                    : progress
                await self.periodicNowPlayingPush(elapsed: publishedProgress)
                await self.checkScrobbleThreshold()
                await self.checkPrefetchThreshold()
                await self.checkAutomaticDownload()
                await self.checkFadeOutThreshold()
            }
        }
    }

    func recoverUnexpectedProgressReset(progress: Double) async -> Bool {
        guard pendingRestoreInfo == nil, !isTrackTransitionPending, seekState == .idle,
              Self.didEngineProgressWrap(previous: lastObservedEngineProgress, current: progress) else { return false }
        let epoch = playbackEpoch
        let previous = lastObservedEngineProgress
        let request = seekRequestGeneration
        let commandID = transportCommandID
        let snapshot = await MainActor.run { (state.duration, state.playbackState.hasPlaybackIntent, state.isLiveStream) }
        guard epoch == playbackEpoch, request == seekRequestGeneration, commandID == transportCommandID,
              !Task.isCancelled, snapshot.1, !snapshot.2,
              !gaplessBridge.wasSelected,
              !Self.isClockResetNearEnd(previous: previous, duration: snapshot.0) else { return false }
        await recoverUnexpectedStreamReset(position: previous)
        return true
    }

    nonisolated static func isClockResetNearEnd(previous: Double, duration: Double) -> Bool {
        duration.isFinite && duration > 0 && previous >= duration - 1
    }

    private func durationIsEstimate() -> Bool {
        !systemPlayback.isActive || currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) == true
    }

    private func preservesCatalogDuration() -> Bool {
        currentSource?.supportsTranscodeOffset == true
            || currentSource.map(AudioQualityClassifier.isLossyTranscodeStream) == true
    }

    func reconcilePendingSeek(engineProgress: TimeInterval, allowsPausedOffset: Bool = false) -> (isSettling: Bool, target: TimeInterval?) {
        guard !Task.isCancelled else { return (true, seekState.target) }
        // An offset is our requested origin, not proof that the new response has produced
        // audio. Keep the target pinned until its own media clock actually advances.
        if systemPlayback.isActive, systemEngine.isSeeking || systemEngine.lastSeekFailed {
            return (true, seekState.target)
        }
        if !allowsPausedOffset, currentSource?.supportsTranscodeOffset == true,
           activeEngine.progress <= 0.05,
           case .settling(let target, let deadline) = seekState, Date() < deadline {
            return (true, target)
        }
        // A broad server-segment tolerance can accept a local parser's old clock, especially
        // for short backwards seeks. Local files can land accurately without that concession.
        let tolerance: TimeInterval = currentSource?.isLocal == true || seekBufferURL != nil ? 0.15 : 2.5
        switch seekState.reconcile(progress: engineProgress, now: Date(), tolerance: tolerance) {
        case .inactive:
            return (false, nil)
        case .waiting(let target):
            return (true, target)
        case .finished(let target, let landed):
            lastObservedEngineProgress = engineProgress
            if landed { systemPlayback.seekSettleDeadline = .distantPast }
            if !landed {
                seekState = .settling(target: target, deadline: Date().addingTimeInterval(600))
                let generation = systemPlayback.generation
                Task { [weak self] in await self?.recoverFailedSeek(target: target, failedGeneration: generation) }
                Logger.player.warning(
                    "[SEEK] engine did not reach target in time target=\(target, format: .fixed(precision: 1))s engine=\(engineProgress, format: .fixed(precision: 1))s"
                )
            }
            return (!landed, target)
        }
    }

    /// When AudioStreaming never reports EOF (common on AirPlay), advance from progress alone.
    func checkEndOfTrackFallback(progress: Double) async {
        let context = playbackContext
        let request = seekRequestGeneration
        let (playbackState, duration, isLiveStream) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream)
        }
        guard contextIsCurrent(context), request == seekRequestGeneration else { return }
        guard case .playing = playbackState, !isLiveStream, duration > 1 else {
            endOfTrackStallStartedAt = nil
            lastObservedEngineProgress = progress
            return
        }

        let previousProgress = lastObservedEngineProgress
        lastObservedEngineProgress = progress

        // A restore seek, an armed engine rebuild or a foreground health-check rebuild all reset
        // the engine clock mid-track. That reset is not end of track — app state and engine are
        // simply out of step while the restart settles — so it must never advance the queue.
        #if os(iOS)
        let engineIsRestarting = pendingRestoreInfo != nil || restorePauseTask != nil || isRebuildingEngine || isTrackTransitionPending
        #else
        let engineIsRestarting = pendingRestoreInfo != nil || restorePauseTask != nil || isTrackTransitionPending
        #endif
        if engineIsRestarting {
            endOfTrackStallStartedAt = nil
            return
        }

        // AudioStreaming resets progress when it reaches EOF (and when a queued entry begins).
        // Server duration metadata is frequently inaccurate, so requiring the old progress to
        // be near that metadata can leave the engine replaying from zero under stale UI state.
        // User seeks cannot enter here while settling and reset `lastObservedEngineProgress` to
        // their target, which makes this wrap test safe for backward scrubbing.
        if Self.didEngineProgressWrap(previous: previousProgress, current: progress) {
            Logger.player.info(
                "[END-OF-TRACK] detected engine progress wrap (previous=\(previousProgress, format: .fixed(precision: 2))s current=\(progress, format: .fixed(precision: 2))s bridge=\(self.gaplessBridge.next != nil))"
            )
            endOfTrackStallStartedAt = nil
            await handleEndOfTrack(engineConfirmed: gaplessBridge.next != nil)
            return
        }

        // Do not advance merely because metadata says 0.2s remain. That used to race the real
        // EOF callback and could consume a gapless bridge before its audio had actually moved.
        // Only use the fallback after progress has genuinely stopped near the end.
        let remaining = duration - progress
        guard remaining <= 0.80 else {
            endOfTrackStallStartedAt = nil
            return
        }
        if endOfTrackStallStartedAt == nil || abs(progress - endOfTrackStallProgress) > 0.08 {
            endOfTrackStallStartedAt = Date()
            endOfTrackStallProgress = progress
            return
        }
        guard let started = endOfTrackStallStartedAt,
              Date().timeIntervalSince(started) >= 1.5 else { return }
        Logger.player.info(
            "[END-OF-TRACK] stall watchdog fired near end (progress=\(progress, format: .fixed(precision: 2))s remaining=\(remaining, format: .fixed(precision: 2))s)"
        )
        endOfTrackStallStartedAt = nil
        await handleEndOfTrack(engineConfirmed: false)
    }

    func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func checkSustainedPlaybackStall(progress: Double) async {
        let epoch = playbackEpoch
        let snapshot = await MainActor.run { (state.playbackState, state.isLiveStream) }
        guard epoch == playbackEpoch, !Task.isCancelled else { return }
        let intendsToPlay = snapshot.0.hasPlaybackIntent
        let stalled = progressStallMonitor.observe(
            mediaTime: progress,
            now: ProcessInfo.processInfo.systemUptime,
            cannotPlay: intendsToPlay && !snapshot.1,
            isSeeking: seekState != .idle || isTrackTransitionPending
                || pendingRestoreInfo != nil || Date() < systemPlayback.seekSettleDeadline
        )
        if stalled, !systemPlayback.recoveredCurrentStall {
            // Resolving a replacement must not freeze progress/seek reconciliation.
            Task { [weak self] in await self?.recoverFromStalledStream() }
        }
    }
}
