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
    // MARK: - NowPlaying position push

    func reassertCurrentNowPlayingSnapshot(rate: Float? = nil) async {
        let epoch = nowPlayingEpoch
        let (track, position, playbackState, duration, isLiveStream, queueIndex, queueCount) = await MainActor.run {
            (state.currentTrack, state.position, state.playbackState, state.duration,
             state.isLiveStream, state.currentIndex, state.queue.count)
        }
        guard let track, !isLiveStream else { return }
        guard epoch == nowPlayingEpoch else { return }

        let resolvedRate: Float
        if let rate {
            resolvedRate = rate
        } else if case .playing = playbackState {
            resolvedRate = 1.0
        } else {
            resolvedRate = 0.0
        }

        let clampedPosition = duration > 0 ? min(position, duration) : position
        let earlySnapshot = NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: clampedPosition,
            playbackRate: resolvedRate,
            artworkURL: nil,
            artworkHeaders: [:],
            coverArtId: track.effectiveCoverArtId,
            albumId: track.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: track),
            trackId: track.id,
            queueIndex: queueIndex,
            queueCount: queueCount
        )
        await nowPlayingService?.publishTrackChange(earlySnapshot)
        guard epoch == nowPlayingEpoch else { return }

        let artworkURL = await resolveArtworkURL(for: track)
        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            artworkHeaders = [:]
        }
        guard epoch == nowPlayingEpoch else { return }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: clampedPosition,
            playbackRate: resolvedRate,
            artworkURL: artworkURL,
            artworkHeaders: artworkHeaders,
            coverArtId: track.effectiveCoverArtId,
            albumId: track.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: track),
            trackId: track.id,
            queueIndex: queueIndex,
            queueCount: queueCount
        ))
        if let ws = widgetSyncService {
            Task { [weak ws] in await ws?.onPlayStateChanged(isPlaying: resolvedRate > 0, currentSong: track) }
        }
    }

    func pushPositionSnapshot(rate: Float? = nil) async {
        let epoch = nowPlayingEpoch
        let (track, position, playbackState, duration, queueIndex, queueCount) = await MainActor.run {
            (state.currentTrack, state.position, state.playbackState, state.duration,
             state.currentIndex, state.queue.count)
        }
        guard let track else { return }
        guard epoch == nowPlayingEpoch else { return }

        let resolvedRate: Float
        if let rate {
            resolvedRate = rate
        } else if case .playing = playbackState {
            resolvedRate = 1.0
        } else {
            resolvedRate = 0.0
        }

        let clampedPosition = duration > 0 ? min(position, duration) : position
        let snapshot = NowPlayingSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.albumName,
            duration: duration,
            position: clampedPosition,
            playbackRate: resolvedRate,
            artworkURL: nil,
            artworkHeaders: [:],
            coverArtId: track.effectiveCoverArtId,
            albumId: track.albumId,
            isLiveStream: false,
            radioStationName: nil,
            isrc: cachedISRC(for: track),
            trackId: track.id,
            queueIndex: queueIndex,
            queueCount: queueCount
        )
        guard epoch == nowPlayingEpoch else { return }
        await nowPlayingService?.update(with: snapshot)
    }

    func periodicNowPlayingPush(elapsed: TimeInterval) async {
        // Most progress ticks do not publish; avoid a MainActor hop until a push is due.
        let now = Date()
        guard now.timeIntervalSince(lastNowPlayingPushDate) >= 5.0 else { return }
        let epoch = nowPlayingEpoch
        let (playbackState, duration, isLiveStream, hasTrack) = await MainActor.run {
            (state.playbackState, state.duration, state.isLiveStream, state.currentTrack != nil)
        }
        guard case .playing = playbackState, !isLiveStream, hasTrack else { return }
        guard elapsed >= 0, duration > 0 else { return }
        guard epoch == nowPlayingEpoch else { return }
        // Halve MediaRemote XPC churn; iOS interpolates lock-screen progress via playbackRate.
        guard now.timeIntervalSince(lastNowPlayingPushDate) >= 5.0 else { return }
        lastNowPlayingPushDate = now
        let clamped = min(elapsed, duration)
        guard epoch == nowPlayingEpoch else { return }
        await nowPlayingService?.pushPosition(elapsed: clamped, rate: 1.0, duration: duration)
        // OpenSubsonic playbackReport (Navidrome 0.62+) — keep server Now Playing rich without double-scrobbling.
        if now.timeIntervalSince(lastPlaybackReportAt) >= 30 {
            if let songId = await MainActor.run(body: { state.currentTrack?.id }) {
                await reportOpenSubsonicPlayback(
                    state: .playing,
                    songId: songId,
                    positionMs: Int(clamped * 1000)
                )
            }
            if let context = currentSource?.jellyfinPlaybackContext {
                await reportJellyfinProgress(context, position: clamped, isPaused: false)
            }
        }
    }

    func reportJellyfinStarted(_ context: JellyfinPlaybackContext, position: TimeInterval) async {
        guard let jellyfinService else { return }
        do {
            try await jellyfinService.perform(feature: .playbackReporting) { client in
                try await client.reportPlaybackStarted(
                    itemID: context.itemID,
                    positionTicks: Self.jellyfinTicks(position),
                    playSessionID: context.playSessionID,
                    mediaSourceID: context.mediaSourceID,
                    playMethod: context.playMethod
                )
            }
        } catch {
            Logger.player.debug("Jellyfin playback start report skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportJellyfinProgress(
        _ context: JellyfinPlaybackContext,
        position: TimeInterval,
        isPaused: Bool
    ) async {
        guard let jellyfinService else { return }
        do {
            let volume = Int((max(0, min(1, Double(restoredVolume))) * 100).rounded())
            try await jellyfinService.perform(feature: .playbackReporting) { client in
                try await client.reportPlaybackProgress(
                    itemID: context.itemID,
                    positionTicks: Self.jellyfinTicks(position),
                    playSessionID: context.playSessionID,
                    isPaused: isPaused,
                    volumeLevel: volume
                )
            }
        } catch {
            Logger.player.debug("Jellyfin playback progress report skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportJellyfinStopped(_ context: JellyfinPlaybackContext, position: TimeInterval) async {
        guard let jellyfinService else { return }
        do {
            try await jellyfinService.perform(feature: .playbackReporting) { client in
                try await client.reportPlaybackStopped(
                    itemID: context.itemID,
                    positionTicks: Self.jellyfinTicks(position),
                    playSessionID: context.playSessionID
                )
            }
        } catch {
            Logger.player.debug("Jellyfin playback stop report skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func jellyfinTicks(_ seconds: TimeInterval) -> Int64 {
        Int64(max(0, seconds) * 10_000_000)
    }

    /// Best-effort OpenSubsonic `reportPlayback` (ignoreScrobble — Cassette still uses classic scrobble).
    func reportOpenSubsonicPlayback(
        state reportState: SwiftSonicClient.PlaybackReportState,
        songId: String,
        positionMs: Int
    ) async {
        // Always advance the throttle timestamp — even on failure — so a persistently
        // timing-out server can't turn the intended 30s cadence into a 2.5s retry storm.
        lastPlaybackReportAt = Date()

        do {
            if playbackReportSupported == nil {
                let client = try await serverService.makeSwiftSonicClient()
                let caps = try? await client.loadCapabilities()
                playbackReportSupported = caps?.supports(.playbackReport) ?? false
            }
            guard playbackReportSupported == true else { return }

            let client = try await serverService.makeSwiftSonicClient()
            try await client.reportPlayback(
                mediaId: songId,
                positionMs: positionMs,
                state: reportState,
                ignoreScrobble: true
            )
        } catch {
            Logger.player.debug(
                "playbackReport skipped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // nonisolated: safe — only called during app termination
    nonisolated func stopAudioEngineSync() {
        engine.stop()
        systemEngine.stop()
    }
}
