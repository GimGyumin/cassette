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
    // MARK: - Crossfade prefetch

    func cancelPendingPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchScheduled = false
    }

    nonisolated static func shouldSchedulePrefetch(crossfadeDuration: Double, remaining: Double) -> Bool {
        guard crossfadeDuration > 0 else { return false }
        return remaining <= crossfadeDuration + 15.0
    }

    /// Crossfade prefetch is a background spend: on a limited (metered or constrained) network it
    /// stays opt-in, exactly like the ephemeral cache it exists to warm.
    nonisolated static func shouldProceedWithPrefetch(isLimited: Bool, allowCellular: Bool) -> Bool {
        if isLimited && !allowCellular { return false }
        return true
    }

    func checkPrefetchThreshold() async {
        guard !prefetchScheduled else { return }
        #if os(iOS)
        // Prefetch can compete with the current stream on wireless system routes.
        guard !PlayerService.isWirelessSystemRouteActive() else { return }
        #endif
        let (currentIndex, duration, position) = await MainActor.run {
            (state.currentIndex, state.duration, state.position)
        }
        guard duration > 0 else { return }
        let remaining = duration - position
        guard PlayerService.shouldSchedulePrefetch(crossfadeDuration: crossfadeConfig.duration, remaining: remaining) else { return }

        let nextIndex = currentIndex + 1
        let resolved: (nextSong: DisplayableSong, serverId: UUID)? = await MainActor.run {
            guard state.queue.indices.contains(nextIndex),
                  let serverId = serverService.state.activeServer?.id else { return nil }
            return (state.queue[nextIndex], serverId)
        }
        guard let resolved else { return }

        prefetchScheduled = true
        Logger.player.debug("[PREFETCH] scheduling prefetch for '\(resolved.nextSong.title, privacy: .public)'")
        await prefetchNextTrack(nextSong: resolved.nextSong, serverId: resolved.serverId)
    }

    private func prefetchNextTrack(nextSong: DisplayableSong, serverId: UUID) async {
        let songId = nextSong.id

        if await cacheService.cachedURL(forSongId: songId, serverId: serverId) != nil {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' already cached")
            return
        }
        if await downloadService.isDownloaded(songId: songId, serverId: serverId) {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' already downloaded")
            return
        }

        let (isLimited, allowCellular) = await MainActor.run {
            (serverService.state.isLimitedNetwork, cacheSettings.cacheOverCellular)
        }
        guard PlayerService.shouldProceedWithPrefetch(isLimited: isLimited, allowCellular: allowCellular) else {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' skipped — limited network")
            return
        }

        guard let streamURL = (try? await serverService.makeSwiftSonicClient())?.streamURL(
            id: songId,
            maxBitRate: 0,
            format: nil
        ) else {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' no stream URL")
            return
        }

        let customHeaders: [String: String]
        do {
            customHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' credentials unavailable")
            return
        }

        prefetchTask = Task { [prefetchSession, weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await self?.downloadAndCache(
                    songId: songId,
                    serverId: serverId,
                    streamURL: streamURL,
                    customHeaders: customHeaders,
                    using: prefetchSession
                )
                Logger.player.info("[PREFETCH] '\(songId, privacy: .public)' prefetch complete")
            } catch {
                Logger.player.debug("[PREFETCH] '\(songId, privacy: .public)' prefetch failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Crossfade fade engine

    func cancelFadeTasks() {
        let wasActive = fadeOutTask != nil || fadeInTask != nil || isFadingOut
        fadeOutTask?.cancel()
        fadeOutTask = nil
        fadeInTask?.cancel()
        fadeInTask = nil
        isFadingOut = false
        if wasActive {
            let vol = restoredVolume
            setEngineVolume(vol)
            Logger.crossfade.info("fade cancelled — volume restored to \(vol, format: .fixed(precision: 2))")
        }
    }

    nonisolated static func isGaplessPair(
        currentAlbumId: String?,
        currentTrackNumber: Int?,
        nextAlbumId: String?,
        nextTrackNumber: Int?
    ) -> Bool {
        // Delegates to `GaplessPolicy` so the crossfade exemption and the bridge share one rule.
        GaplessPolicy.isAlbumPair(
            currentAlbumId: currentAlbumId,
            currentTrackNumber: currentTrackNumber,
            nextAlbumId: nextAlbumId,
            nextTrackNumber: nextTrackNumber
        )
    }

    nonisolated static func shouldStartFadeOut(
        crossfadeDuration: Double,
        remaining: Double,
        hasNext: Bool,
        trackDuration: Double,
        repeatOne: Bool = false
    ) -> Bool {
        guard crossfadeDuration > 0, hasNext else { return false }
        guard !repeatOne else { return false }
        guard trackDuration > 2 * crossfadeDuration else { return false }
        return remaining > 0 && remaining <= crossfadeDuration
    }

    nonisolated static func didEngineProgressWrap(previous: Double, current: Double) -> Bool {
        previous >= 5 && current >= 0 && current < 1 && current + 2 < previous
    }

    func checkFadeOutThreshold() async {
        guard !isFadingOut else { return }
        guard crossfadeConfig.duration > 0 else { return }
        let (duration, position, isPlaying, currentIndex, queueCount, repeatMode, title) = await MainActor.run {
            (state.duration, state.position, state.playbackState == .playing,
             state.currentIndex, state.queue.count, state.repeatMode,
             state.currentTrack?.title ?? "?")
        }
        guard isPlaying, duration > 0 else { return }
        let remaining = duration - position
        let D = crossfadeConfig.duration
        let hasNext = currentIndex + 1 < queueCount || repeatMode != .off

        if remaining > 0 && remaining <= D {
            if !hasNext {
                Logger.crossfade.debug("skip — no-next track")
            } else if repeatMode == .one {
                Logger.crossfade.debug("skip — repeat-one (track='\(title, privacy: .public)')")
            } else if duration <= 2 * D {
                Logger.crossfade.debug("skip — short track")
            }
        }

        guard PlayerService.shouldStartFadeOut(
            crossfadeDuration: D,
            remaining: remaining,
            hasNext: hasNext,
            trackDuration: duration,
            repeatOne: repeatMode == .one
        ) else { return }

        if crossfadeConfig.disableForGapless {
            let (currentSong, nextSong): (DisplayableSong?, DisplayableSong?) = await MainActor.run {
                let nextIndex = state.currentIndex + 1
                return (state.currentTrack, state.queue.indices.contains(nextIndex) ? state.queue[nextIndex] : nil)
            }
            if let current = currentSong, let next = nextSong,
               PlayerService.isGaplessPair(
                   currentAlbumId: current.albumId,
                   currentTrackNumber: current.trackNumber,
                   nextAlbumId: next.albumId,
                   nextTrackNumber: next.trackNumber
               ) {
                Logger.crossfade.debug("skip — gapless pair")
                return
            }
        }

        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }
        guard !PlayerService.isWirelessSystemRoute(portTypes: outputs) else {
            Logger.crossfade.debug("skip — wireless system route")
            return
        }
        #endif

        isFadingOut = true
        let userVol = restoredVolume
        Logger.crossfade.info("fade-out START — targetVol=\(String(format:"%.2f",userVol))->0")
        performFadeOut(duration: remaining)
    }

    nonisolated static func crossfadeVolume(base: Float, progress: Double, phase: CrossfadePhase) -> Float {
        let p = max(0.0, min(1.0, progress))
        switch phase {
        case .fadeOut: return base * Float(cos(p * .pi / 2))
        case .fadeIn:  return base * Float(sin(p * .pi / 2))
        }
    }

    private func performFadeOut(duration: Double) {
        let startVolume = engineVolume()
        let fadeDuration = max(duration, 0.05)
        fadeOutTask = Task { [weak self] in
            guard let self else { return }
            let startTime = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / fadeDuration, 1.0)
                await self.setEngineVolume(PlayerService.crossfadeVolume(base: startVolume, progress: progress, phase: .fadeOut))
                if progress >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func performFadeIn(duration: Double) {
        let fadeDuration = max(duration, 0.05)
        fadeInTask = Task { [weak self] in
            guard let self else { return }
            Logger.crossfade.info("fade-in START vol=0->target=\(self.restoredVolume, format: .fixed(precision: 2))")
            let startTime = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startTime)
                let progress = min(elapsed / fadeDuration, 1.0)
                let target = self.restoredVolume
                await self.setEngineVolume(PlayerService.crossfadeVolume(base: target, progress: progress, phase: .fadeIn))
                if progress >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            if !Task.isCancelled {
                let final = self.restoredVolume
                await self.setEngineVolume(final)
                Logger.crossfade.info("fade-in DONE")
            }
        }
    }

    #if os(iOS)
    nonisolated static func isWirelessSystemRoute(portTypes: [AVAudioSession.Port]) -> Bool {
        let wireless: Set<AVAudioSession.Port> = [.airPlay, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return portTypes.contains(where: { wireless.contains($0) })
    }

    nonisolated static func isWirelessSystemRouteActive() -> Bool {
        isWirelessSystemRoute(
            portTypes: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        )
    }

    nonisolated static func isPersonalAudioRoute(portTypes: [AVAudioSession.Port]) -> Bool {
        let personal: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio
        ]
        return portTypes.contains(where: { personal.contains($0) })
    }
    #endif
}
