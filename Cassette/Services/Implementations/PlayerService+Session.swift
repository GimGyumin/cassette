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
    // MARK: - Session persistence

    func saveCurrentPosition() async {
        let pos = engineProgress()
        guard pos > 0 else { return }
        await sessionService.savePosition(pos)
    }

    func handleAppBecameActive() async {
        #if os(iOS)
        if needsArtworkPreloadRecheck {
            needsArtworkPreloadRecheck = false
            preloadNextTrackArtwork()
        }
        await handleAppBecameActiveiOS()
        #endif
    }

    /// Inactive (Control Center, app switcher peek): do not mark health-check — brief
    /// inactive + buffering used to false-trigger a full engine rebuild and freeze UI.
    func handleAppWillResignActive() async {}

    /// True background only — schedule a progress health-check when returning to foreground.
    func handleAppDidEnterBackground() async {
        #if os(iOS)
        let (isPlaying, uiPos, songId) = await MainActor.run {
            (state.playbackState == .playing, state.position, state.currentTrack?.id)
        }
        if isPlaying && !usingSystemPlayer {
            mayNeedPlaybackHealthCheck = true
            // Prefer UI scrubber + engine — after suspend `engine.progress` may collapse to ~0.
            lastForegroundProgress = max(engine.progress, uiPos)
            lastForegroundProgressSongId = songId
            await sessionService.savePosition(lastForegroundProgress)
        }
        #endif
    }

    func saveSession() async {
        let snapshot = await MainActor.run {
            SessionPayload(
                currentIndex: state.currentIndex,
                currentPosition: state.position,
                queue: state.queue,
                currentTrack: state.currentTrack,
                repeatMode: state.repeatMode
            )
        }
        await sessionService.save(playerState: snapshot)
    }

    func restoreSession() async {
        // A Siri/App Intent request can begin playback while the deferred cold-start restore
        // is waiting for Home. Never let that old persisted session overwrite live playback.
        guard await MainActor.run(body: { state.currentTrack == nil && state.playbackState == .idle }) else {
            Logger.player.info("[RESTORE] skipped because playback is already active")
            return
        }
        guard let data = await sessionService.loadRestoredSession() else { return }
        guard await MainActor.run(body: { state.currentTrack == nil && state.playbackState == .idle }) else {
            Logger.player.info("[RESTORE] discarded because playback started while loading the session")
            return
        }
        guard data.queue.indices.contains(data.currentIndex) else {
            Logger.player.error("Session restore: invalid index \(data.currentIndex) for queue of \(data.queue.count) — clearing")
            await sessionService.clear()
            return
        }

        let track = data.queue[data.currentIndex]
        await MainActor.run {
            state.queue = data.queue
            state.currentIndex = data.currentIndex
            state.currentTrack = track
            state.currentRadio = nil
            state.position = data.currentPosition
            state.duration = data.currentTrackDuration
            state.repeatMode = data.repeatMode
            state.playbackState = .paused
        }

        if data.repeatMode == .off,
           data.currentIndex == data.queue.count - 1,
           data.currentTrackDuration > 0,
           data.currentPosition >= data.currentTrackDuration - 0.1 {
            stoppedAtEndOfQueue = true
            Logger.player.info("[RESTORE] session was parked at end of queue")
        }

        await prepareCurrentTrackForRestoration(track: track, position: data.currentPosition)
        Logger.player.info("Session restored: \(data.queue.count) tracks, index \(data.currentIndex), pos=\(data.currentPosition, format: .fixed(precision: 1))s")
    }

    private func prepareCurrentTrackForRestoration(track: DisplayableSong, position: TimeInterval) async {
        isRestoringSession = true

        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            Logger.player.warning("Session restore: no active server")
            isRestoringSession = false
            return
        }

        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: track.id, serverId: serverId, song: track)
        } catch {
            Logger.player.error("Session restore: failed to resolve media — \(error)")
            await MainActor.run { state.isPlaybackAvailable = false }
            isRestoringSession = false
            return
        }

        stopProgressTimer()
        currentSource = source
        pendingRestoreInfo = (seekTime: position, pause: true)
        #if os(macOS)
        // A restored macOS session must stay on the platform's single AVPlayer path
        // when the user presses Play after relaunching the app.
        usingSystemPlayer = true
        #else
        // Match the engine to the restored track so resume() routes a Spatial/multichannel
        // track back through AVPlayer instead of the stereo-only AudioStreaming path.
        // Without this, a restored Atmos track silently fails (or is downmixed) on resume.
        usingSystemPlayer = AudioQualityClassifier.requiresSystemPlayer(track)
            || PlayerService.isWirelessSystemRouteActive()
        #endif

        let config = await MainActor.run { replayGainSettings.config }
        await replayGainService?.apply(track: track, config: config)
        Logger.player.debug("[RESTORE] ReplayGain applied")

        await MainActor.run { state.isPlaybackAvailable = true }
        Logger.player.info("Session restore: '\(track.title)' queued at \(position, format: .fixed(precision: 1))s")

        let (duration, restoredQueueIndex, restoredQueueCount) = await MainActor.run {
            (state.duration, state.currentIndex, state.queue.count)
        }
        let artworkURL = await resolveArtworkURL(for: track)
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        resolvedISRCForCurrentTrack = track.isrc
        resolvedISRCSongId = track.id
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: position,
            playbackRate: 0.0,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: track.effectiveCoverArtId,
            albumId: track.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: track.isrc,
            trackId: track.id,
            queueIndex: restoredQueueIndex,
            queueCount: restoredQueueCount
        ))
        Task.detached { [weak self] in
            await self?.resolveAndPublishISRC(for: track)
        }
        // Cold-start restore no longer auto-plays (avoids phantom audio). The `.playing`
        // callback therefore may never arrive until the user taps play — do not discard the
        // seek target on a timer. Only clear the restore *lock* so end-of-track / network
        // handlers are not blocked forever.
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard isRestoringSession else { return }
            if let info = pendingRestoreInfo, info.pause {
                Logger.player.info(
                    "[RESTORE] idle restore settled — retaining seek \(info.seekTime, format: .fixed(precision: 1))s until play"
                )
                isRestoringSession = false
                return
            }
            if pendingRestoreInfo != nil {
                Logger.player.warning("[RESTORE] safety clear — playing callback never arrived")
                pendingRestoreInfo = nil
            }
            isRestoringSession = false
        }
    }

    func handleNetworkRestored() async {
        guard !isRestoringSession else {
            Logger.player.info("Network restored — session restore in progress")
            return
        }
        let (isAvailable, track, position) = await MainActor.run {
            (state.isPlaybackAvailable, state.currentTrack, state.position)
        }
        guard !isAvailable, let track else { return }
        Logger.player.info("Network restored — re-preparing '\(track.title)'")
        await prepareCurrentTrackForRestoration(track: track, position: position)
    }

    // MARK: - Position save timer

    func startPositionSaveTimer() {
        stopPositionSaveTimer()
        positionSaveTask = Task {
            while !Task.isCancelled {
                // 5s — not 1s. Each SwiftData save merges into mainContext and can hitch the UI.
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                if isRestoringSession { continue }
                guard engineIsSeekable() else { continue }
                let (isPlaying, pos) = await MainActor.run {
                    (state.playbackState == .playing, state.position)
                }
                guard isPlaying else { continue }
                await sessionService.savePosition(pos)
            }
        }
    }

    func stopPositionSaveTimer() {
        positionSaveTask?.cancel()
        positionSaveTask = nil
    }
}
