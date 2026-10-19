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
        await savePositionCheckpoint(pos)
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
        if isPlaying && !systemPlayback.isActive {
            mayNeedPlaybackHealthCheck = true
            // Prefer UI scrubber + engine — after suspend `engine.progress` may collapse to ~0.
            lastForegroundProgress = max(engineProgress(), uiPos)
            lastForegroundProgressSongId = songId
            await savePositionCheckpoint(lastForegroundProgress)
        }
        #endif
    }

    func savePositionCheckpoint(_ position: TimeInterval) async {
        guard !isTrackTransitionPending else { return }
        let publication = makePlaybackPublication()
        let snapshot = await MainActor.run { (state.currentTrack?.id, state.currentIndex, serverService.state.activeServer?.id) }
        guard publication.isCurrent, !isTrackTransitionPending,
              let trackID = snapshot.0, let accountID = snapshot.2 else { return }
        let identity = PlaybackCheckpointIdentity(accountID: accountID, trackID: trackID,
            queueIndex: snapshot.1, revision: "\(sessionLifetimeID.uuidString).\(publication.context.epoch)")
        await sessionService.savePosition(position, identity: identity, publication: publication)
    }

    func saveSession() async {
        let publication = makePlaybackPublication()
        let (snapshot, accountID) = await MainActor.run {
            (SessionPayload(currentIndex: state.currentIndex, currentPosition: state.position,
                queue: state.queue, currentTrack: state.currentTrack, repeatMode: state.repeatMode),
             serverService.state.activeServer?.id)
        }
        guard publication.isCurrent, let accountID, let trackID = snapshot.currentTrack?.id else { return }
        let identity = PlaybackCheckpointIdentity(accountID: accountID, trackID: trackID,
            queueIndex: snapshot.currentIndex, revision: "\(sessionLifetimeID.uuidString).\(publication.context.epoch)")
        await sessionService.save(playerState: snapshot, identity: identity, publication: publication)
    }

    /// Used only by the explicit recovery action in Playback settings. The source row is kept.
    func restoreLegacySession() async {
        let publication = makePlaybackPublication()
        let account = await MainActor.run { state.currentTrack == nil ? serverService.state.activeServer?.id : nil }
        guard publication.isCurrent, let account,
              await sessionService.copyLegacySession(to: account, publication: publication),
              publication.isCurrent else { return }
        transport.intent = .pause
        await restoreSession()
    }

    func restoreSession() async {
        guard stopBarrierCount == 0, transport.intent != .stop,
              await permitsNewTransportCommand() else { return }
        let epoch = playbackEpoch
        let command = transportCommandID
        let expectedServer = await MainActor.run { serverService.state.activeServer?.id }
        // A Siri/App Intent request can begin playback while the deferred cold-start restore
        // is waiting for Home. Never let that old persisted session overwrite live playback.
        guard await MainActor.run(body: { state.currentTrack == nil && state.playbackState == .idle }) else {
            Logger.player.info("[RESTORE] skipped because playback is already active")
            return
        }
        guard let expectedServer,
              let data = await sessionService.loadRestoredSession(accountID: expectedServer),
              epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled,
              await MainActor.run(body: { serverService.state.activeServer?.id == expectedServer }) else { return }
        guard await MainActor.run(body: { state.currentTrack == nil && state.playbackState == .idle }) else {
            Logger.player.info("[RESTORE] discarded because playback started while loading the session")
            return
        }
        guard data.queue.indices.contains(data.currentIndex) else {
            Logger.player.error("Session restore: invalid index \(data.currentIndex) for queue of \(data.queue.count) — clearing")
            // Preserve unreadable/legacy rows for recovery instead of deleting user data.
            return
        }

        let track = data.queue[data.currentIndex]
        let installed = await commitPresentation(PlaybackContext(command: command, epoch: epoch)) { state in
            guard state.currentTrack == nil, state.playbackState == .idle, !Task.isCancelled,
                  serverService.state.activeServer?.id == expectedServer else { return false }
            state.queue = data.queue
            state.currentIndex = data.currentIndex
            state.currentTrack = track
            state.currentRadio = nil
            state.position = data.currentPosition
            state.pendingSeekPosition = nil
            state.duration = data.currentTrackDuration
            state.repeatMode = data.repeatMode
            state.playbackState = .paused
            return true
        }
        guard installed, epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return }

        if data.repeatMode == .off,
           data.currentIndex == data.queue.count - 1,
           data.currentTrackDuration > 0,
           data.currentPosition >= data.currentTrackDuration - 0.1 {
            stoppedAtEndOfQueue = true
            Logger.player.info("[RESTORE] session was parked at end of queue")
        }

        await prepareCurrentTrackForRestoration(track: track, position: data.currentPosition,
                                                serverID: expectedServer, epoch: epoch, command: command)
        guard epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return }
        await saveSession() // establish this process's occurrence token before any checkpoint
        Logger.player.info("Session restored: \(data.queue.count) tracks, index \(data.currentIndex), pos=\(data.currentPosition, format: .fixed(precision: 1))s")
    }

    private func prepareCurrentTrackForRestoration(track: DisplayableSong, position: TimeInterval,
                                                 serverID: UUID?, epoch: UInt64, command: UInt64) async {
        guard let serverId = serverID else {
            Logger.player.warning("Session restore: no active server")
            if epoch == playbackEpoch, command == transportCommandID { isRestoringSession = false }
            return
        }
        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
        isRestoringSession = true

        let source: MediaSource
        do {
            source = try await mediaResolver.resolve(songId: track.id, serverId: serverId, song: track)
        } catch {
            guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
            Logger.player.error("Session restore: failed to resolve media — \(error)")
            await MainActor.run { state.isPlaybackAvailable = false }
            isRestoringSession = false
            return
        }

        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }

        stopProgressTimer()
        currentSource = source
        pendingRestoreInfo = (seekTime: position, pause: true)
        #if os(macOS)
        // A restored macOS session must stay on the platform's single AVPlayer path
        // when the user presses Play after relaunching the app.
        systemPlayback.isActive = true
        #else
        // Match the engine to the restored track so resume() routes a Spatial/multichannel
        // track back through AVPlayer instead of the stereo-only AudioStreaming path.
        // Without this, a restored Atmos track silently fails (or is downmixed) on resume.
        systemPlayback.isActive = AudioQualityClassifier.requiresSystemPlayer(source.playbackSong ?? track)
            || PlayerService.isWirelessSystemRouteActive()
        #endif

        let config = await MainActor.run { replayGainSettings.config }
        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
        await applyReplayGain(track: source.playbackSong ?? track, config: config,
                              context: PlaybackContext(command: command, epoch: epoch))
        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
        Logger.player.debug("[RESTORE] ReplayGain applied")

        await MainActor.run { state.isPlaybackAvailable = true; state.currentPlaybackTrack = source.playbackSong }
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
        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
        let publication = makePlaybackPublication()
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
            queueCount: restoredQueueCount,
            publication: publication
        ))
        guard await restorationIsCurrent(trackID: track.id, serverID: serverId, epoch: epoch, command: command) else { return }
        Task.detached { [weak self] in
            await self?.resolveAndPublishISRC(for: track)
        }
        // Cold-start restore no longer auto-plays (avoids phantom audio). The `.playing`
        // callback therefore may never arrive until the user taps play — do not discard the
        // seek target on a timer. Only clear the restore *lock* so end-of-track / network
        // handlers are not blocked forever.
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard epoch == playbackEpoch, command == transportCommandID,
                  !Task.isCancelled, isRestoringSession else { return }
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

    private func restorationIsCurrent(trackID: String, serverID: UUID, epoch: UInt64, command: UInt64) async -> Bool {
        guard epoch == playbackEpoch, command == transportCommandID, !Task.isCancelled else { return false }
        let matches = await MainActor.run {
            state.currentTrack?.id == trackID && state.playbackState == .paused
                && serverService.state.activeServer?.id == serverID
        }
        return matches && epoch == playbackEpoch && command == transportCommandID && !Task.isCancelled
    }

    func handleNetworkRestored() async {
        guard stopBarrierCount == 0, transport.intent != .stop,
              await permitsNewTransportCommand() else { return }
        guard !isRestoringSession else {
            Logger.player.info("Network restored — session restore in progress")
            return
        }
        let (isAvailable, track, position, serverID) = await MainActor.run {
            (state.isPlaybackAvailable, state.currentTrack, state.position, serverService.state.activeServer?.id)
        }
        guard !isAvailable, let track else { return }
        Logger.player.info("Network restored — re-preparing '\(track.title)'")
        await prepareCurrentTrackForRestoration(track: track, position: position,
                                                serverID: serverID, epoch: playbackEpoch, command: transportCommandID)
    }

    // MARK: - Position save timer

    func startPositionSaveTimer() {
        checkpointScheduler.start { [weak self] in
            await self?.savePeriodicPosition()
        }
    }

    private func savePeriodicPosition() async {
        guard !Task.isCancelled, !isRestoringSession, engineIsSeekable() else { return }
        let epoch = playbackEpoch
        let (isPlaying, position) = await MainActor.run {
            (state.playbackState == .playing, state.position)
        }
        guard epoch == playbackEpoch, !Task.isCancelled, isPlaying else { return }
        await savePositionCheckpoint(position)
    }

    func stopPositionSaveTimer() {
        checkpointScheduler.stop()
    }
}
