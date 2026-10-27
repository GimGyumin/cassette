// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import MediaPlayer
import OSLog
#if os(iOS)
import UIKit
#endif

extension NowPlayingService {
    func refreshArtworkPresentation() async {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            await MainActor.run {
                guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info.removeValue(forKey: MPNowPlayingInfoProperty3x4AnimatedArtwork)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
            if let currentSong { await displayArtwork(currentSong) }
        }
        #endif
    }

    func refreshDownloadedArtwork(coverID: String) async {
        guard let snapshot = currentSong else { return }
        let prepared = await preparedCoverIdProvider?(snapshot.albumId)
        guard coverID == snapshot.effectiveCoverArtId || coverID == prepared else { return }
        guard isCurrent(snapshot) else { return }
        await displayArtwork(snapshot)

    }

    #if os(iOS)
    func installForegroundArtworkRetryObserver() {
        guard foregroundRetryObserver == nil else { return }
        foregroundRetryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.retryPendingArtwork() }
        }
    }

    private func retryPendingArtwork() async {
        guard let pendingArtwork else { return }
        await displayArtwork(pendingArtwork.snapshot)
    }
    #endif

    /// Album id → the cover recorded during library preparation (the one a download stored).
    private func preparedCoverArtId(for snapshot: NowPlayingSnapshot) async -> String? {
        guard let preparedCoverIdProvider else { return nil }
        return await MainActor.run { preparedCoverIdProvider(snapshot.albumId) }
    }

    /// RAM → the downloaded cover → tiered/offline disk; `nil` when this candidate has no local copy.
    ///
    /// Local only on purpose, so `displayArtwork` can check *every* candidate before a single server
    /// request is made. The download's own file (`coverarts/<id>`, written verbatim at full resolution)
    /// comes before the streaming cache: it is the cover the listener chose to keep, the only cover that
    /// exists offline, and the same image the in-app player shows for a downloaded album.
    private func lockScreenArtwork(coverArtId: String) async -> PlatformImage? {
        if let downloaded = await artworkImageCache.loadPlainDiskCover(coverArtId: coverArtId, tier: .hero) {
            Logger.nowPlaying.info(
                "[NOWPLAYING-ARTWORK] '\(coverArtId, privacy: .public)' served from the downloaded cover"
            )
            return downloaded
        }
        if let image = await artworkImageCache.load(coverArtId: coverArtId, tier: .hero, allowNetwork: false) { return image }
        return nil
    }

    /// Attaches `image` to the Now Playing dictionary and maintains the retry bookkeeping.
    ///
    /// An image that exists but cannot be attached — the system dictionary was momentarily absent, or
    /// still carried the outgoing track's identifier — is kept pending instead of dropped, so the next
    /// position push retries it; dropping it here left the lock screen blank until the following track.
    private func finishArtwork(
        _ image: PlatformImage,
        snapshot: NowPlayingSnapshot,
        generation: Int
    ) async -> Bool {
        let installed = await installArtwork(
            ArtworkLoader.makeArtwork(image),
            for: snapshot,
            generation: generation
        )
        #if os(iOS)
        if installed, #available(iOS 26.0, *),
           UserDefaults.standard.object(forKey: "cassette.visuals.immersiveAlbums") as? Bool != false,
           MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork),
           let tall = await LockScreenImmersiveArtwork.make(image) {
            await MainActor.run {
                guard artworkRevision.matches(generation),
                      UserDefaults.standard.object(forKey: "cassette.visuals.immersiveAlbums") as? Bool != false,
                      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = tall
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        #endif
        if installed, generation == artworkGeneration {
            pendingArtwork = nil
            hasArtwork = true
            artworkRetryAttempt = 0
            artworkRetryDate = .distantPast
        } else if generation == artworkGeneration {
            pendingArtwork = pendingArtwork ?? (snapshot, snapshot.artworkHeaders)
        }
        return installed
    }

    /// Attempts to resolve artwork for `snapshot` from cache or network and attaches it to
    /// the current Now Playing info. Clears `pendingArtwork` on success so a background
    /// auto-advance gets a best-effort foreground backfill without stomping newer tracks.
    func displayArtwork(_ snapshot: NowPlayingSnapshot) async {
        guard isCurrent(snapshot) else { return }
        let generation = artworkGeneration
        guard artworkLoadGeneration != generation else { return }
        artworkLoadGeneration = generation
        defer { if artworkLoadGeneration == generation { artworkLoadGeneration = nil } }

        // A prepared album image must never replace a track's distinct artwork.
        var candidateIds: [String] = []
        if let own = snapshot.effectiveCoverArtId {
            candidateIds.append(own)
        } else if let prepared = await preparedCoverArtId(for: snapshot) {
            candidateIds.append(prepared)
        }
        Logger.nowPlaying.debug(
            "[NOWPLAYING-ARTWORK] candidates for '\(snapshot.title, privacy: .public)': \(candidateIds.joined(separator: ", "), privacy: .public)"
        )

        // Search *all* candidates for permanent originals before accepting any derivative.
        for id in candidateIds {
            if let image = await artworkImageCache.loadPlainDiskCover(coverArtId: id, tier: .hero) {
                guard generation == artworkGeneration, isCurrent(snapshot) else { return }
                _ = await finishArtwork(image, snapshot: snapshot, generation: generation)
                return
            }
        }

        // Every candidate is checked locally first. A network fetch for candidate #1 used to end the
        // search before candidate #2 — the song's own id, which is the id a download stores its cover
        // file under — had been tried at all, so the lock screen could keep showing a server downscale
        // instead of the downloaded cover.
        for coverArtId in candidateIds {
            guard generation == artworkGeneration, isCurrent(snapshot) else { return }
            if let cachedImage = await lockScreenArtwork(coverArtId: coverArtId) {
                guard generation == artworkGeneration, isCurrent(snapshot) else { return }
                _ = await finishArtwork(cachedImage, snapshot: snapshot, generation: generation)
                return
            }
        }

        // Paint a small cached sleeve immediately, but keep resolving the hero tier.
        // A thumbnail is a useful first frame, not the final full-screen artwork.
        for coverArtId in candidateIds {
            if let thumbnail = await artworkImageCache.load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false) {
                guard generation == artworkGeneration, isCurrent(snapshot) else { return }
                let installed = await installArtwork(ArtworkLoader.makeArtwork(thumbnail), for: snapshot,
                                                     generation: generation, isPreview: true)
                guard generation == artworkGeneration, isCurrent(snapshot) else { return }
                if installed { hasArtwork = true }
                // Keep upgrade retries bounded; preview publication must not reset
                // the failure count each time the same thumbnail is found again.
                pendingArtwork = (snapshot, snapshot.artworkHeaders)
                break
            }
        }

        // Nothing local matched. Only now is a server request justified: each candidate through the
        // shared authenticated pipeline, then the snapshot's own URL below.
        for coverArtId in candidateIds {
            guard generation == artworkGeneration, isCurrent(snapshot) else { return }
            guard let fetched = await artworkImageCache.load(
                coverArtId: coverArtId,
                tier: .hero,
                allowNetwork: true,
                playbackPriority: true
            ) else { continue }
            guard generation == artworkGeneration, isCurrent(snapshot) else { return }
            _ = await finishArtwork(fetched, snapshot: snapshot, generation: generation)
            return
        }

        guard generation == artworkGeneration, isCurrent(snapshot) else { return }
        // No candidate resolved locally — every disk tier (including the downloaded cover) missed, so
        // log the ids that were tried: a blank lock screen for a downloaded album almost always means
        // the cover id the snapshot carries is not the id the download stored its file under.
        if !candidateIds.isEmpty {
            Logger.nowPlaying.info(
                "[NOWPLAYING-ARTWORK] no local cover for the current track — every candidate id missed on disk"
            )
        }
        // Fetch artwork in the background too. The previous background guard left the
        // lock screen / Apple Watch without cover art for Siri-started or auto-advanced
        // tracks, because a cover is rarely cached before its first play. The loader is a
        // separate, timeout-bounded URLSession that can't starve the audio stream; on
        // failure `pendingArtwork` still defers a best-effort foreground retry.
        guard let artworkURL = snapshot.artworkURL else {
            if candidateIds.isEmpty {
                Logger.nowPlaying.warning(
                    "[NOWPLAYING-ARTWORK] nothing to load for '\(snapshot.title, privacy: .public)' — no cover id and no artwork URL"
                )
            }
            scheduleArtworkRetry(snapshot, generation: generation)
            return
        }
        // The URL fallback follows the same cellular/offline policy as the shared cache.
        let allowsNetwork = await artworkImageCache.allowsNetworkDownloads
        guard artworkURL.isFileURL || allowsNetwork else {
            scheduleArtworkRetry(snapshot, generation: generation)
            return
        }
        guard let artwork = await artworkLoader.artwork(for: artworkURL, headers: snapshot.artworkHeaders) else {
            scheduleArtworkRetry(snapshot, generation: generation)
            return
        }
        guard generation == artworkGeneration, isCurrent(snapshot) else { return }
        let installed = await installArtwork(artwork, for: snapshot, generation: generation)
        if installed, generation == artworkGeneration {
            pendingArtwork = nil
            hasArtwork = true
            artworkRetryAttempt = 0
            artworkRetryDate = .distantPast
        } else {
            scheduleArtworkRetry(snapshot, generation: generation)
        }
    }

    private func scheduleArtworkRetry(_ snapshot: NowPlayingSnapshot, generation: Int) {
        guard generation == artworkGeneration, isCurrent(snapshot) else { return }
        pendingArtwork = (snapshot, snapshot.artworkHeaders)
        artworkRetryAttempt += 1
        artworkRetryDate = Date().addingTimeInterval(min(30 * pow(2, Double(artworkRetryAttempt - 1)), 300))
    }

    /// Artwork commonly finishes after one or more position pushes. Merge only the artwork
    /// into the current dictionary so a delayed image can never rewind the system scrubber
    /// with the snapshot position captured at track start.
    func installArtwork(
        _ artwork: MPMediaItemArtwork,
        for snapshot: NowPlayingSnapshot,
        generation: Int,
        isPreview: Bool = false
    ) async -> Bool {
        await MainActor.run {
            guard artworkRevision.matches(generation),
                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
                Logger.nowPlaying.warning(
                    "[NOWPLAYING-ARTWORK] dropped for '\(snapshot.title, privacy: .public)' — Now Playing dictionary unavailable or superseded"
                )
                return false
            }
            if let expected = snapshot.externalContentIdentifier,
               let current = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
               current != expected {
                Logger.nowPlaying.warning(
                    "[NOWPLAYING-ARTWORK] dropped for '\(snapshot.title, privacy: .public)' — the Now Playing slot belongs to another item"
                )
                return false
            }
            if isPreview, let current = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
               max(current.bounds.width, current.bounds.height) > max(artwork.bounds.width, artwork.bounds.height) {
                return true
            }
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            Logger.nowPlaying.debug(
                "[NOWPLAYING-ARTWORK] installed for '\(snapshot.title, privacy: .public)'"
            )
            return true
        }
    }

    func isCurrent(_ snapshot: NowPlayingSnapshot) -> Bool {
        guard let currentSong else { return false }
        if let current = currentSong.publication, let candidate = snapshot.publication,
           current.context.epoch != candidate.context.epoch { return false }
        if currentSong.queueIndex != snapshot.queueIndex { return false }
        if currentSong.trackId != nil || snapshot.trackId != nil {
            return currentSong.trackId == snapshot.trackId
        }
        return currentSong.title == snapshot.title
            && currentSong.artist == snapshot.artist
            && currentSong.album == snapshot.album
            && currentSong.coverArtId == snapshot.coverArtId
            && currentSong.isLiveStream == snapshot.isLiveStream
    }
}
