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
    private nonisolated static func makeNowPlayingInfo(
        for snapshot: NowPlayingSnapshot,
        artwork: MPMediaItemArtwork? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        if snapshot.isLiveStream {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }

        if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let isrc = snapshot.isrc, !isrc.isEmpty {
            info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = isrc
        }
        if let identifier = snapshot.externalContentIdentifier {
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] = identifier
        }
        if let index = snapshot.queueIndex, index >= 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        }
        if let count = snapshot.queueCount, count > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = count
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        return info
    }

    private nonisolated static func makeNowPlayingInfo(
        for snapshot: NowPlayingSnapshot,
        image: PlatformImage
    ) -> [String: Any] {
        makeNowPlayingInfo(for: snapshot, artwork: ArtworkLoader.makeArtwork(image))
    }

    // MARK: - Update

    func update(with snapshot: NowPlayingSnapshot) async {
        await updateModernMediaSession(with: snapshot)
        if snapshot.isLiveStream {
            artworkRetryTask?.cancel()
            artworkRetryTask = nil
            hasArtwork = false
            artworkRetryAttempt = 0
            artworkRetryDate = .distantPast
            artworkGeneration &+= 1
            let generation = artworkGeneration
            currentSong = snapshot
            pendingArtwork = nil
            // Live stream: fresh dict with the IsLiveStream flag set.
            // Duration and elapsed time are intentionally omitted — Control Center hides
            // the scrubber automatically when MPNowPlayingInfoPropertyIsLiveStream is true.
            let baseInfo = Self.makeNowPlayingInfo(for: snapshot)
            await MainActor.run {
                guard artworkRevision.accept(generation) else { return }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = baseInfo
                #if os(macOS)
                MPNowPlayingInfoCenter.default().playbackState = .playing
                #endif
            }
            #if os(macOS)
            postDiscordRPC(.nowPlaying(.init(
                title: snapshot.title,
                artist: snapshot.artist ?? "",
                album: snapshot.album ?? "",
                duration: snapshot.duration,
                startedAt: Date().timeIntervalSince1970
            )))
            #endif

            // Check ArtworkImageCache — use hero tier for lock screen / Control Center quality.
            if let coverArtId = snapshot.effectiveCoverArtId,
               let cachedImage = await artworkImageCache.cached(for: coverArtId, tier: .hero) {
                _ = await installArtwork(
                    ArtworkLoader.makeArtwork(cachedImage),
                    for: snapshot,
                    generation: generation
                )
            }

            await updateRemoteCommandsAvailability(isLiveStream: true)
            return
        }

        await updateRemoteCommandsAvailability(isLiveStream: false)

        let isTrackChange = !isCurrent(snapshot)
        if !isTrackChange {
            if snapshot.artworkURL != nil { currentSong = snapshot }
            let generation = artworkGeneration
            // Position-only update (pause/resume/seek): merge into the existing dict so
            // artwork already loaded for the current track is preserved.
            await MainActor.run {
                guard artworkRevision.matches(generation) else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyTitle] = snapshot.title
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
                info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
                info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.playbackRate
                info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
                if let artist = snapshot.artist { info[MPMediaItemPropertyArtist] = artist }
                if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
                if let isrc = snapshot.isrc, !isrc.isEmpty {
                    info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = isrc
                }
                if let index = snapshot.queueIndex, index >= 0 {
                    info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
                }
                if let count = snapshot.queueCount, count > 0 {
                    info[MPNowPlayingInfoPropertyPlaybackQueueCount] = count
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                #if os(macOS)
                MPNowPlayingInfoCenter.default().playbackState = snapshot.playbackRate > 0 ? .playing : .paused
                #endif
            }
            #if os(macOS)
            if snapshot.playbackRate == 0 {
                postDiscordRPC(.stopped)
            } else if let song = currentSong {
                postDiscordRPC(.nowPlaying(.init(
                    title: song.title,
                    artist: song.artist ?? "",
                    album: song.album ?? "",
                    duration: song.duration,
                    startedAt: Date().timeIntervalSince1970
                )))
            }
            #endif
            if !hasArtwork { await displayArtwork(currentSong ?? snapshot) }
            return
        }

        // New track: build from scratch so stale artwork from the previous track is cleared
        // before the new one loads. Text metadata is committed first so the lockscreen
        // doesn't flash empty while the artwork fetch is in progress.
        let info = Self.makeNowPlayingInfo(for: snapshot)
        artworkRetryTask?.cancel()
        artworkRetryTask = nil
        currentSong = snapshot
        artworkGeneration &+= 1
        hasArtwork = false
        artworkRetryAttempt = 0
        artworkRetryDate = .distantPast
        let generation = artworkGeneration
        pendingArtwork = nil
        let baseInfo = info
        await MainActor.run {
            guard artworkRevision.accept(generation) else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = baseInfo
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = snapshot.playbackRate > 0 ? .playing : .paused
            #endif
        }
        #if os(macOS)
        postDiscordRPC(.nowPlaying(.init(
            title: snapshot.title,
            artist: snapshot.artist ?? "",
            album: snapshot.album ?? "",
            duration: snapshot.duration,
            startedAt: Date().timeIntervalSince1970
        )))
        #endif

        await displayArtwork(snapshot)
    }

    // MARK: - Periodic position push

    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async {
        guard elapsed >= 0, duration > 0, elapsed <= duration else { return }
        #if os(iOS)
        if #available(iOS 27.0, *),
           let controller = modernMediaSession as? CassetteMediaSessionController {
            await controller.updatePlayback(elapsed: elapsed, rate: rate)
        }
        #endif
        if !hasArtwork,
           artworkRetryAttempt < Self.maximumArtworkRetryAttempts,
           let pendingArtwork,
           artworkRetryTask == nil,
           Date() >= artworkRetryDate {
            artworkRetryTask = Task {
                await displayArtwork(pendingArtwork.snapshot)
                artworkRetryTask = nil
            }
        }
        await MainActor.run {
            // Don't invent a Now Playing session before metadata (incl. ISRC) has been published.
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  info[MPMediaItemPropertyTitle] != nil else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            info[MPMediaItemPropertyPlaybackDuration] = duration
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
            #endif
        }
    }

    func setISRC(_ isrc: String) async {
        let trimmed = isrc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await MainActor.run {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  info[MPMediaItemPropertyTitle] != nil else { return }
            info[MPNowPlayingInfoPropertyInternationalStandardRecordingCode] = trimmed
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        Logger.player.debug("Now Playing ISRC set for Music Haptics")
    }

    func setPlaybackRate(_ rate: Float) async {
        await MainActor.run {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  info[MPMediaItemPropertyTitle] != nil else { return }
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
            #endif
        }
    }

    func clearISRC() async {
        await MainActor.run {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info.removeValue(forKey: MPNowPlayingInfoPropertyInternationalStandardRecordingCode)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func publishTrackChange(_ snapshot: NowPlayingSnapshot) async {
        await updateModernMediaSession(with: snapshot)
        // Fresh dict without artwork so the previous track's ISRC/rate cannot linger
        // while we resolve cover art / credentials on the full update path.
        let info = Self.makeNowPlayingInfo(for: snapshot)
        artworkRetryTask?.cancel()
        artworkRetryTask = nil
        currentSong = snapshot
        pendingArtwork = nil
        artworkGeneration &+= 1
        hasArtwork = false
        artworkRetryAttempt = 0
        artworkRetryDate = .distantPast
        let generation = artworkGeneration
        let published = info
        await MainActor.run {
            guard artworkRevision.accept(generation) else { return }
            var metadata = published
            if let image = artworkImageCache.cached(for: snapshot.effectiveCoverArtId, tier: .hero)
                ?? artworkImageCache.cached(for: snapshot.effectiveCoverArtId, tier: .thumb) {
                metadata[MPMediaItemPropertyArtwork] = ArtworkLoader.makeArtwork(image)
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = snapshot.playbackRate > 0 ? .playing : .paused
            #endif
        }
        await updateRemoteCommandsAvailability(isLiveStream: snapshot.isLiveStream)
    }

    func updateModernMediaSession(with snapshot: NowPlayingSnapshot) async {
        #if os(iOS)
        if #available(iOS 27.0, *),
           let controller = modernMediaSession as? CassetteMediaSessionController {
            let serverId = await MainActor.run { serverState?.activeServer?.id }
            await controller.update(snapshot, serverId: serverId)
        }
        #endif
    }
}


extension NowPlayingSnapshot {
    nonisolated var externalContentIdentifier: String? {
        if let trackId, !trackId.isEmpty {
            return "cassette.track.\(trackId)"
        }
        if let coverArtId, !coverArtId.isEmpty {
            return "cassette.cover.\(coverArtId)"
        }

        let parts = [title, artist, album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return "cassette.track.\(parts.joined(separator: "|"))"
    }
}

