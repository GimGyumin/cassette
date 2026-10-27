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

// MARK: - iOS Audio Session

#if os(iOS)
extension PlayerService {
    func configureAudioSessionIfNeeded(preferMultichannel: Bool = true) {
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // Re-applying setCategory while audio is running causes audible glitches during
            // app switches. Only configure category/multichannel once; afterwards just
            // re-activate the session (iOS may have deactivated it after an interruption).
            if !audioSessionConfigured {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                try session.setSupportsMultichannelContent(true)
                audioSessionConfigured = true
                Logger.player.info("[SPATIAL] AVAudioSession configured — longFormAudio + multichannel")
            }

            if preferMultichannel {
                let maxChannels = session.maximumOutputNumberOfChannels
                // Speakers / HDMI / receiver: request full bed. AirPods report 2 but still
                // render Atmos via Spatial Audio when supportsMultichannelContent is true.
                if maxChannels > 2 {
                    let preferred = min(maxChannels, 8)
                    try? session.setPreferredOutputNumberOfChannels(preferred)
                }
            } else if session.maximumOutputNumberOfChannels > 2 {
                // Clear sticky surround preference so stereo tracks don't keep a wide bus.
                try? session.setPreferredOutputNumberOfChannels(2)
            }

            try session.setActive(true)
        } catch let error as NSError {
            if error.code == -50 {
                // Code=-50: another app holds the session — retry after short delay.
                Logger.player.warning("AVAudioSession setActive Code=-50, retrying in 0.5s")
                let epoch = playbackEpoch
                let command = transportCommandID
                sessionActivationRetryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
                    await self?.retryAudioSessionActivation(epoch: epoch, command: command)
                }
            } else {
                // Category may need a hard reset after media-services reset.
                audioSessionConfigured = false
                Logger.player.error("Failed to configure AVAudioSession: \(error, privacy: .public)")
            }
        }
        installAudioSessionObserversIfNeeded()
    }

    private func retryAudioSessionActivation(epoch: UInt64, command: UInt64) {
        guard !Task.isCancelled, epoch == playbackEpoch, command == transportCommandID,
              transport.intent == .play, !transport.interrupted, stopBarrierCount == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func installAudioSessionObserversIfNeeded() {
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                Task { await self.handleAudioSessionInterruption(notification) }
            }
        }
        if screenshotObserver == nil {
            screenshotObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.userDidTakeScreenshotNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.noteScreenshotTaken() }
            }
        }
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let changeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
                // AVAudioSessionRouteDescription is not Sendable — extract the previous
                // route's port types here on the main queue before hopping to the actor.
                let previousOutputs = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                    as? AVAudioSessionRouteDescription)?.outputs.map(\.portType) ?? []
                Task { await self.handleRouteChange(changeReason, previousOutputs: previousOutputs) }
            }
        }
        if spatialCapabilitiesObserver == nil {
            spatialCapabilitiesObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let enabled = (notification.userInfo?[AVAudioSessionSpatialAudioEnabledKey] as? Bool) ?? false
                Logger.player.info("[SPATIAL] capabilities changed — enabled=\(enabled, privacy: .public)")
                Task { await self?.logSpatialRouteStatus() }
            }
            mediaServicesResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Logger.player.warning("[AUDIO] media services were reset — will reconfigure session")
                Task { await self?.handleMediaServicesReset() }
            }
        }
    }

    func handleAppBecameActiveiOS() async {
        guard !audioInterruptionActive else { return }
        // Foregrounding is not evidence that the audio session needs reactivation.
        pendingScreenshotResume = false

        let isPlaying = await MainActor.run { state.playbackState == .playing }
        if isPlaying {
            // Re-sync Lock Screen / Control Center after background. Re-publish full metadata
            // because auto-advance can happen while the app is suspended.
            await reassertCurrentNowPlayingSnapshot(rate: 1.0)
            if mayNeedPlaybackHealthCheck {
                mayNeedPlaybackHealthCheck = false
                await verifyPlaybackHealthyOrRebuild()
            }
        } else {
            mayNeedPlaybackHealthCheck = false
        }
    }

    /// Reactivate the shared session and resume the engine without fighting mid-interruption.
    /// Avoids aggressive rebuilds (those left longFormAudio wedged → silent system audio).
    private func resumeAfterSystemInterruption() async {
        guard transport.permitsAudio else { return }
        let context = playbackContext
        interruptedWhilePlaying = false
        let shouldHealthCheck = mayNeedPlaybackHealthCheck
        mayNeedPlaybackHealthCheck = false

        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Logger.player.warning(
                "[INTERRUPTION] setActive(true) failed: \(error.localizedDescription, privacy: .public) — resetting category"
            )
            audioSessionConfigured = false
            configureAudioSessionIfNeeded(preferMultichannel: systemPlayback.isActive)
        }

        if currentSource?.isLiveStream != true {
            // A stopped/failed engine needs the same source refresh and retained seek as a
            // manual resume. Calling engine.resume() alone can leave it permanently silent.
            await resume()
            if shouldHealthCheck { await verifyPlaybackHealthyOrRebuild() }
            return
        }

        guard await commitPresentation(context, { state in
            state.playbackState = state.playbackState.resuming(reopensSource: false, position: state.position)
            return true
        }) else { return }

        if systemPlayback.isActive {
            if systemEngine.state != .playing {
                systemEngine.resume()
                Logger.player.info("[INTERRUPTION] AVPlayer resumed")
            }
            startProgressTimer()
            await pushPositionSnapshot(rate: 1.0)
            return
        }

        let engineState = engine.state
        if engineState == .paused || engineState == .ready || engineState == .stopped {
            engine.resume()
            Logger.player.info("[INTERRUPTION] AudioStreaming resumed (state was \(String(describing: engineState), privacy: .public))")
            startProgressTimer()
        } else if shouldHealthCheck, engineState == .playing {
            await verifyPlaybackHealthyOrRebuild()
        } else if engineState == .playing {
            startProgressTimer()
        } else {
            // Bufferring / unknown — nudge resume once.
            engine.resume()
            startProgressTimer()
            Logger.player.info("[INTERRUPTION] AudioStreaming nudged resume from \(String(describing: engineState), privacy: .public)")
        }
        await pushPositionSnapshot(rate: 1.0)
    }

    /// If AudioStreaming claims to play but the scrubber doesn't advance, rebuild once.
    /// Always resume at the pre-suspend position — never at a reset engine progress (~0.2s).
    private func verifyPlaybackHealthyOrRebuild() async {
        // The inactive AudioStreaming engine reports zero progress while AVPlayer
        // is playing. Resuming/rebuilding it here starts a second audible engine.
        guard !systemPlayback.isActive else { return }
        let checkedEpoch = playbackEpoch
        let checkedSeek = seekRequestGeneration
        let checkedCommand = transportCommandID
        // Ignore while a restore seek is still pending — progress is expected to stall briefly.
        if pendingRestoreInfo != nil { return }

        let (uiPos, songId) = await MainActor.run { (state.position, state.currentTrack?.id) }
        guard !systemPlayback.isActive, checkedEpoch == playbackEpoch, !Task.isCancelled else { return }
        // Only reuse the background checkpoint for the same song — auto-skip in background
        // leaves a stale high anchor that looks like "engine reset".
        let bgAnchor = (songId != nil && songId == lastForegroundProgressSongId)
            ? lastForegroundProgress : 0
        let anchored = max(engineProgress(), uiPos, bgAnchor)

        // Soft nudge when the engine woke paused/stopped/buffering after suspend.
        let wakeState = engine.state
        if wakeState != .playing {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                audioSessionConfigured = false
                configureAudioSessionIfNeeded(preferMultichannel: false)
            }
            engine.resume()
            startProgressTimer()
            try? await Task.sleep(for: .milliseconds(700))
        }

        guard !systemPlayback.isActive, checkedEpoch == playbackEpoch, !Task.isCancelled else { return }

        let sampleA = engineProgress()
        try? await Task.sleep(for: .milliseconds(1000))
        let stillPlaying = await MainActor.run { state.playbackState == .playing }
        guard stillPlaying, !systemPlayback.isActive, checkedEpoch == playbackEpoch,
              checkedSeek == seekRequestGeneration, checkedCommand == transportCommandID,
              pendingRestoreInfo == nil, seekState == .idle, !Task.isCancelled else { return }
        let sampleB = engineProgress()
        let engineState = engine.state

        // Engine progress collapsed under us after suspend (classic HTTP stream drop).
        let resetUnderUs = anchored > 2 && sampleB + 1.0 < anchored
        // True .playing but scrubber not advancing. Never rebuild on .bufferring alone.
        let notAdvancing = engineState == .playing && sampleB <= sampleA + 0.05

        if resetUnderUs || notAdvancing {
            Logger.player.warning(
                "[ACTIVE] playback stuck at \(anchored, format: .fixed(precision: 1))s after background — rebuilding (engine=\(sampleB, format: .fixed(precision: 1))s)"
            )
            await rebuildAudioStreaming(at: anchored)
        }
    }

    /// Tear down and restart AudioStreaming at a known-good scrub position.
    /// Uses the in-memory source only — never awaits network — so rapid app switching cannot
    /// stall the entire PlayerService actor.
    private func rebuildAudioStreaming(at position: TimeInterval) async {
        let epoch = playbackEpoch
        guard !systemPlayback.isActive, !Task.isCancelled else { return }
        guard !isRebuildingEngine else {
            Logger.player.debug("[ACTIVE] rebuild skipped — already in progress")
            return
        }
        guard let source = currentSource else { return }

        let now = Date()
        if now.timeIntervalSince(lastEngineRebuildAt) < 2.5 {
            Logger.player.debug("[ACTIVE] rebuild skipped — debounced")
            return
        }

        isRebuildingEngine = true
        lastEngineRebuildAt = now
        defer { isRebuildingEngine = false }

        let seekTo = max(0, position)
        Logger.player.info(
            "[ACTIVE] rebuilding AudioStreaming from \(seekTo, format: .fixed(precision: 1))s after suspend"
        )
        guard await publishEngineRecovery(), epoch == playbackEpoch, !systemPlayback.isActive else { return }
        pendingRestoreInfo = (seekTime: seekTo, pause: false)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            audioSessionConfigured = false
            configureAudioSessionIfNeeded(preferMultichannel: false)
        }
        engine.stop()
        startEnginePlayback(url: source.url, headers: source.customHeaders, useSystemPlayer: seekTo > 0)
        Task { @MainActor in PlaybackBeatMeter.shared.setEnabled(true) }
    }

    private func handleMediaServicesReset() async {
        audioSessionConfigured = false
        audioInterruptionActive = false
        interruptedWhilePlaying = false
        pendingScreenshotResume = false
        screenshotNotedAt = nil
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        hardPausedForCurrentInterruption = false
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        await resetAudioObjectsAfterMediaServicesReset()
        // Session/category activation is performed by the next explicit play/resume request.

    }

    private func noteScreenshotTaken() async {
        // Screenshot often posts interruption without `.shouldResume`. Cancel any deferred
        // hard-pause so we don't crackle/cut audio; resume only on `.ended`.
        // Never rebuild from this notification — mid-interruption rebuild wedged longFormAudio.
        screenshotNotedAt = .now
        // Taking a screenshot alone does not deactivate audio. Do not manufacture
        // a resume request that will reconfigure a healthy session on foregrounding.
        guard audioInterruptionActive, interruptedWhilePlaying, !interruptionWasRouteDisconnect else { return }
        deferredInterruptionPauseTask?.cancel()
        deferredInterruptionPauseTask = nil
        let wantsPlay = await MainActor.run { state.playbackState.hasPlaybackIntent } || interruptedWhilePlaying
        guard wantsPlay else { return }
        pendingScreenshotResume = true
        interruptedWhilePlaying = true
        Logger.player.info("[INTERRUPTION] screenshot noted — soft path (skip/cancel engine pause)")
    }

    /// Hard pause used for real interruptions (call / Siri / other apps). Screenshots cancel
    /// the deferred task that would call this.
    func applyHardInterruptionPause() async {
        let context = playbackContext
        hardPausedForCurrentInterruption = true
        finalizePlaySegment()
        deferredInterruptionPauseTask = nil
        cancelFadeTasks()
        pauseEngine()
        stopProgressTimer()
        await saveCurrentPosition()
        // Reflect the external stop in the app UI immediately — the player is no longer
        // playing. Keep `interruptedWhilePlaying` so `.ended` can decide whether to resume.
        guard await commitPresentation(context, { $0.playbackState = .paused; return true }) else { return }
        await pushPositionSnapshot(rate: 0.0)
        await publishWidgetStatus()
        Logger.player.info(
            "[INTERRUPTION] began — engine paused (routeDisconnect=\(self.interruptionWasRouteDisconnect, privacy: .public); UI set to paused)"
        )
    }

    private func handleAudioSessionInterruption(_ notification: Notification) async {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            let context = beginSystemInterruption()
            audioInterruptionActive = true
            // Record route-disconnect interruptions (AirPods in case) before any early
            // return — .ended must never auto-resume those onto the built-in speaker.
            interruptionWasRouteDisconnect = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) == .routeDisconnected

            let wasPlaying = await MainActor.run { state.playbackState.hasPlaybackIntent }
            guard context == playbackContext, wasPlaying || interruptedWhilePlaying else { return }

            interruptedWhilePlaying = true
            hardPausedForCurrentInterruption = false
            // `.appWasSuspended` is deprecated (gone since iOS 16). Rebuild only after a
            // real background via `mayNeedPlaybackHealthCheck` / become-active health check —
            // never from screenshot interruptions.

            let recentScreenshot = pendingScreenshotResume
                || (screenshotNotedAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false)
            if recentScreenshot, !interruptionWasRouteDisconnect {
                pendingScreenshotResume = true
                deferredInterruptionPauseTask?.cancel()
                deferredInterruptionPauseTask = nil
                Logger.player.info("[INTERRUPTION] began — soft (screenshot); leaving engine running")
                return
            }

            // Defer hard pause so `userDidTakeScreenshotNotification` can cancel it when the
            // interruption arrives first (common race → crackle if we pause immediately). The
            // 380ms window covers the worst-case screenshot-notification latency on older devices
            // where it can lag several hundred ms behind the audio-session interruption.
            deferredInterruptionPauseTask?.cancel()
            deferredInterruptionPauseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled, let self else { return }
                if await self.pendingScreenshotResume { return }
                await self.applyHardInterruptionPause()
            }

        case .ended:
            let context = playbackContext
            guard audioInterruptionActive else { return }
            audioInterruptionActive = false
            transport.interrupted = false
            deferredInterruptionPauseTask?.cancel()
            deferredInterruptionPauseTask = nil
            let neverHardPaused = !hardPausedForCurrentInterruption
            hardPausedForCurrentInterruption = false

            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) }
                .map { $0.contains(.shouldResume) } ?? false
            let wasRouteDisconnect = interruptionWasRouteDisconnect
            interruptionWasRouteDisconnect = false
            let wasPlayingBefore = interruptedWhilePlaying
            Logger.player.info(
                "[INTERRUPTION] ended — shouldResume=\(shouldResume, privacy: .public) wasPlayingBefore=\(wasPlayingBefore, privacy: .public) routeDisconnect=\(wasRouteDisconnect, privacy: .public) screenshotPending=\(self.pendingScreenshotResume, privacy: .public) soft=\(neverHardPaused, privacy: .public)"
            )

            if wasRouteDisconnect {
                if neverHardPaused { await applyHardInterruptionPause() }
                interruptedWhilePlaying = false
                pendingScreenshotResume = false
                screenshotNotedAt = nil
                guard await commitPresentation(context, { $0.playbackState = .paused; return true }) else { return }
                await pushPositionSnapshot(rate: 0.0)
                Logger.player.info("[INTERRUPTION] ended — route disconnect, staying paused")
                return
            }

            // Screenshots omit shouldResume — resume here so audio returns before dismissing
            // the system screenshot UI (become-active alone felt like a multi-second mute).
            if pendingScreenshotResume && wasPlayingBefore {
                pendingScreenshotResume = false
                screenshotNotedAt = nil
                if wasPlayingBefore {
                    await resumeAfterSystemInterruption()
                } else {
                    interruptedWhilePlaying = false
                }
                return
            }

            // Phone call / Siri / alarm: system asks us to resume.
            // Video / other long-form media: typically shouldResume=false — stay paused.
            if wasPlayingBefore && shouldResume {
                await resumeAfterSystemInterruption()
            } else {
                if neverHardPaused && wasPlayingBefore { await applyHardInterruptionPause() }
                interruptedWhilePlaying = false
                guard await commitPresentation(context, { $0.playbackState = .paused; return true }) else { return }
                await pushPositionSnapshot(rate: 0.0)
                Logger.player.info("[INTERRUPTION] ended — staying paused")
            }

        @unknown default:
            break
        }
    }

    // internal: accessible from tests via @testable import
    func handleRouteChange(
        _ reason: AVAudioSession.RouteChangeReason,
        previousOutputs: [AVAudioSession.Port] = []
    ) async {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        Logger.player.info("[ROUTE] routeChange reason=\(reason.logDescription, privacy: .public) outputs=[\(outputs, privacy: .public)]")

        switch reason {
        case .oldDeviceUnavailable:
            // Personal listening device went away (AirPods in case, headphones unplugged).
            // Require a known previous personal route — empty previousOutputs must NOT pause
            // (app-switch / routeConfiguration noise previously stopped playback).
            guard !previousOutputs.isEmpty,
                  PlayerService.isPersonalAudioRoute(portTypes: previousOutputs) else { break }
            let hasActiveTrack = await MainActor.run {
                state.currentTrack != nil && state.playbackState != .idle
            }
            if hasActiveTrack { await pause() }

        case .newDeviceAvailable:
            // Only re-activate when we are not mid-interruption.
            guard !interruptedWhilePlaying else { break }
            // Avoid fighting route picker / Translation — a light delay lets the route settle.
            try? await Task.sleep(for: .milliseconds(150))
            guard !interruptedWhilePlaying else { break }
            try? AVAudioSession.sharedInstance().setActive(true)
            // Stereo tracks were on AudioStreaming — migrate to AVPlayer for wireless route stability.
            await migrateToSystemPlayerIfWirelessRoute()

        case .routeConfigurationChange:
            // Common during screenshot / Control Center / route picker chrome — do NOT setActive
            // while interrupted (that fought the system and left other apps silent). Also skip
            // while lyrics Apple Translation may be contending for the same process budget.
            guard !interruptedWhilePlaying else { break }
            // No-op setActive here: unnecessary re-activation during picker UI caused underruns
            // when lyrics translation was also running. newDeviceAvailable handles real switches.
            break

        default:
            break
        }
    }

    /// When a wireless system route becomes active mid-track, rebuild on AVPlayer at the current position.
    private func migrateToSystemPlayerIfWirelessRoute() async {
        let epoch = playbackEpoch
        guard PlayerService.isWirelessSystemRouteActive() else { return }
        guard !systemPlayback.isActive else { return }
        let (isPlaying, hasTrack) = await MainActor.run {
            (state.playbackState.hasPlaybackIntent, state.currentTrack != nil)
        }
        guard epoch == playbackEpoch, isPlaying, hasTrack, let source = currentSource else { return }

        // Route callbacks can arrive while AudioStreaming momentarily reports zero. Keep the
        // last UI checkpoint as a second anchor so migration never restarts the song at 0:00.
        let uiPosition = await MainActor.run { state.position }
        guard epoch == playbackEpoch, !systemPlayback.isActive else { return }
        let position = max(0, engineProgress(), uiPosition)
        Logger.player.info(
            "[ROUTE] migrating AudioStreaming → AVPlayer at \(position, format: .fixed(precision: 1))s"
        )
        guard await publishEngineRecovery(), epoch == playbackEpoch, !systemPlayback.isActive else { return }
        pendingRestoreInfo = (seekTime: position, pause: false)
        startEnginePlayback(
            url: source.url,
            headers: source.customHeaders,
            useSystemPlayer: true
        )
        startProgressTimer()
        await pushPositionSnapshot(rate: 1.0)
    }
}
#endif

// MARK: - iOS logging helpers (file-private)

#if os(iOS)
private extension AVAudioSession.RouteChangeReason {
    nonisolated var logDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
#endif
