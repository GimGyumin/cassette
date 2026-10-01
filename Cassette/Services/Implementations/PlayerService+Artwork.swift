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
    // MARK: - Next track artwork pre-load

    func preloadNextTrackArtwork() {
        Task {
            let isLimited = await MainActor.run { serverService.state.isLimitedNetwork }
            guard !isLimited else {
                // The next track performs its own mandatory presentation preparation before
                // playback. Do not let speculative artwork compete with a limited connection's
                // audio.
                needsArtworkPreloadRecheck = true
                return
            }
            #if os(iOS)
            // Don't open cover-art HTTP while backgrounded — contends with the audio stream.
            // Instead flag the skip so the next foreground transition retries the preload.
            let backgrounded = await MainActor.run { UIApplication.shared.applicationState == .background }
            if backgrounded {
                needsArtworkPreloadRecheck = true
                return
            }
            needsArtworkPreloadRecheck = false
            #endif
            let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
            let nextIndex = currentIndex + 1
            guard nextIndex < queue.count else { return }
            let nextTrack = queue[nextIndex]
            await artworkImageCache.load(coverArtId: nextTrack.effectiveCoverArtId)
        }
    }

    // MARK: - Artwork / NowPlaying helpers

    func resolveArtworkURL(for song: DisplayableSong) async -> URL? {
        guard let client = try? await serverService.makeSwiftSonicClient() else { return nil }
        let artId = song.effectiveCoverArtId
        return client.coverArtURL(id: artId, size: 600)
    }

    /// ISRC for system Music Haptics (Settings → Accessibility → Music Haptics).
    private func resolveISRC(for song: DisplayableSong) async -> String? {
        if let isrc = song.isrc?.trimmingCharacters(in: .whitespacesAndNewlines), !isrc.isEmpty {
            return isrc
        }
        // Catalog ISRC is only worth a network round-trip when enrichment or haptics need it.
        let (shouldLookup, provider) = await MainActor.run { () -> (Bool, ISRCProvider) in
            let enrich = AppleMusicSettings.shared.enrichMetadata
            #if os(iOS)
            let haptics = MusicHapticsController.shared.shouldEngage
            #else
            let haptics = false
            #endif
            return (enrich || haptics, AppleMusicSettings.shared.isrcProvider)
        }
        guard shouldLookup else { return nil }

        // Preferred commercial catalog first (Spotify or Apple Music media token).
        switch provider {
        case .spotify:
            if let isrc = await SpotifyCatalogService.shared.catalogISRC(
                title: song.title,
                artist: song.artist,
                album: song.albumName
            ) {
                return isrc
            }
        case .appleMusic:
            if let isrc = await AppleMusicCatalogService.shared.catalogISRC(
                title: song.title,
                artist: song.artist,
                album: song.albumName
            ) {
                return isrc
            }
        }

        // Free fallback — no API keys required.
        return await MusicBrainzCatalogService.shared.catalogISRC(
            title: song.title,
            artist: song.artist,
            album: song.albumName
        )
    }

    func resolveAndPublishISRC(for song: DisplayableSong) async {
        let isrc = await resolveISRC(for: song)
        let stillCurrent = await MainActor.run { state.currentTrack?.id == song.id }
        guard stillCurrent else { return }
        resolvedISRCForCurrentTrack = isrc
        resolvedISRCSongId = song.id
        guard let isrc else { return }
        await nowPlayingService?.setISRC(isrc)
        #if os(iOS)
        // Do NOT call checkHapticTrackAvailability here — that XPC often fails with
        // sandbox 159 and can delay the real Music Haptics load by tens of seconds.
        // Re-stamp ISRC a few times while playing so the system can attach when ready.
        scheduleMusicHapticsISRCNudge(songId: song.id, isrc: isrc)
        #endif
        prefetchNextTrackISRC()
    }

    /// Soft reasserts of Now Playing ISRC — nudges system Music Haptics without availability probes.
    private func scheduleMusicHapticsISRCNudge(songId: String, isrc: String) {
        musicHapticsNudgeTask?.cancel()
        musicHapticsNudgeTask = Task { [weak self] in
            // Staggered nudges cover the common ~30–90s system load window.
            for delay in [4.0, 15.0, 35.0, 60.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                let stillPlaying = await MainActor.run {
                    // `.loading` counts: the first nudge lands 4 s after the track was requested and
                    // a slow stream can still be opening then. Bailing out here would silently drop
                    // the remaining nudges for that track.
                    self.state.currentTrack?.id == songId
                        && (self.state.playbackState == .playing || self.state.playbackState == .loading)
                }
                guard stillPlaying else { return }
                await self.nowPlayingService?.setISRC(isrc)
                Logger.player.debug(
                    "Music Haptics: reasserted ISRC after \(delay, format: .fixed(precision: 0))s isrc=\(isrc, privacy: .public)"
                )
            }
        }
    }

    private func prefetchNextTrackISRC() {
        nextTrackISRCPrefetchTask?.cancel()
        nextTrackISRCPrefetchTask = Task { [weak self] in
            guard let self else { return }
            let (queue, currentIndex) = await MainActor.run { (self.state.queue, self.state.currentIndex) }
            let nextIndex = currentIndex + 1
            guard nextIndex < queue.count else { return }
            let next = queue[nextIndex]
            // Warm MusicBrainz / Spotify / Apple Music caches only — do not publish Now Playing.
            _ = await self.resolveISRC(for: next)
        }
    }

    func cachedISRC(for song: DisplayableSong) -> String? {
        if resolvedISRCSongId == song.id, let isrc = resolvedISRCForCurrentTrack, !isrc.isEmpty {
            return isrc
        }
        return song.isrc
    }
}
