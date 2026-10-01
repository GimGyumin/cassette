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
        guard automaticDownloadTasks.insert(key).inserted else { return }
        Task {
            defer { automaticDownloadTasks.remove(key) }
            if isLimited {
                // Give the foreground stream time to establish a safe buffer before an optional
                // limited-network download is allowed to share the connection.
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                let stillPlayingThisTrack = await MainActor.run {
                    state.playbackState == .playing && state.currentTrack?.id == song.id
                }
                guard stillPlayingThisTrack else { return }
            }
            guard await MainActor.run(body: {
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
            } catch {
                Logger.download.error("Automatic download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
            }
        }
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
            await scheduleAutomaticDownload(song: song, serverId: serverId)
        }
    }

    func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = CassettePerformance.budget.isAppActive ? .milliseconds(500) : .seconds(1)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
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
                let engineIsEstimate = !(await self.usingSystemPlayer)
                guard epoch == (await self.playbackEpoch), !Task.isCancelled else { continue }
                await MainActor.run {
                    guard !isHandingOver, self.state.currentTrack?.id == trackID else { return }
                    let cur = self.state.isLiveStream ? 0 : PlaybackDurationPolicy.resolve(
                        catalog: self.state.currentTrack?.duration ?? 0,
                        engine: audioDuration,
                        engineIsEstimate: engineIsEstimate
                    )
                    if abs(self.state.duration - cur) > 0.5 || !self.state.duration.isFinite {
                        self.state.duration = cur
                    }
                    if !seekState.isSettling {
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
                guard epoch == (await self.playbackEpoch), !isHandingOver else { continue }
                // Backstop for the engines' own `.playing` confirmation. A track that was started
                // from its beginning and is already reporting audible progress is playing, even if
                // the engine never delivered its state callback — and a state stuck in `.loading`
                // would leave the transport spinning on audible music while keeping the
                // end-of-track watchdog disarmed (it only arms while `.playing`).
                // Bounded to a fresh start: a mid-track recovery (stall retry, restore seek) keeps a
                // non-zero position and stays owned by the engine's own status reporting.
                if positionBeforeTick < 1, progress > 1 {
                    await self.publishEnginePlaybackConfirmation()
                }
                if !seekState.isSettling {
                    await self.checkEndOfTrackFallback(progress: progress)
                }
                let publishedProgress = seekState.isSettling
                    ? (seekState.target ?? progress)
                    : progress
                await self.periodicNowPlayingPush(elapsed: publishedProgress)
                await self.checkScrobbleThreshold()
                await self.checkPrefetchThreshold()
                await self.checkAutomaticDownload()
                await self.checkFadeOutThreshold()
                await self.ensureGaplessPreparation()
            }
        }
    }

    private func reconcilePendingSeek(engineProgress: TimeInterval) -> (isSettling: Bool, target: TimeInterval?) {
        guard let target = pendingSeekTarget else { return (false, nil) }

        // If the engine's clock wrapped back to the start, the requested target was never
        // honoured — the stream restarted (or the engine was rebuilt) instead of seeking. Release
        // the scrubber immediately: holding it at the target is what left the UI frozen on the old
        // position while audio played from zero ("it rewound but the bar did not move"), until the
        // 8-second deadline expired.
        if Self.didEngineProgressWrap(previous: target, current: engineProgress) {
            pendingSeekTarget = nil
            pendingSeekDeadline = .distantPast
            lastObservedEngineProgress = engineProgress
            Logger.player.warning(
                "[SEEK] engine restarted from zero instead of landing on \(target, format: .fixed(precision: 1))s — releasing the scrubber"
            )
            return (false, nil)
        }

        let landed = abs(engineProgress - target) <= 2.5
        let timedOut = Date() >= pendingSeekDeadline
        if landed || timedOut {
            pendingSeekTarget = nil
            pendingSeekDeadline = .distantPast
            lastObservedEngineProgress = engineProgress
            if timedOut && !landed {
                Logger.player.warning(
                    "[SEEK] engine did not reach target in time target=\(target, format: .fixed(precision: 1))s engine=\(engineProgress, format: .fixed(precision: 1))s"
                )
            }
            return (false, target)
        }
        return (true, target)
    }

    /// When AudioStreaming never reports EOF (common on AirPlay), advance from progress alone.
    private func checkEndOfTrackFallback(progress: Double) async {
        let (playbackState, duration, isLiveStream) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream)
        }
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
                "[END-OF-TRACK] detected engine progress wrap (previous=\(previousProgress, format: .fixed(precision: 2))s current=\(progress, format: .fixed(precision: 2))s bridge=\(self.gaplessBridgeNext != nil))"
            )
            endOfTrackStallStartedAt = nil
            await handleEndOfTrack(engineConfirmed: gaplessBridgeNext != nil)
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
}
