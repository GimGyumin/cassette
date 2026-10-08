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
    // MARK: - Scrobble

    func cancelPendingScrobble() {
        playingNowTask?.cancel()
        playingNowTask = nil
        periodicPlaybackReportTask?.cancel()
        periodicPlaybackReportTask = nil
        gaplessMetadataTask?.cancel()
        gaplessMetadataTask = nil
    }

    func checkScrobbleThreshold() async {
        // A track change is in flight: the accumulated time still belongs to the outgoing track,
        // so attributing it to the incoming one would scrobble the wrong song.
        guard !isTrackTransitionPending else { return }
        guard let song = await MainActor.run(body: { state.currentTrack }) else { return }
        fireScrobbleIfThresholdMet(song: song)
    }

    private func fireScrobbleIfThresholdMet(song: DisplayableSong) {
        guard Self.isListeningHistoryEnabled else { return }
        let duration = song.duration
        let songId = song.id
        let segmentContrib = currentPlaySegmentStart.map { Date().timeIntervalSince($0) } ?? 0
        let accumulated = accumulatedPlayedSeconds + segmentContrib
        guard detector.check(duration: duration, accumulated: accumulated) else { return }
        let startDate = trackPlayStartDate ?? Date()
        Task { [libraryService] in
            await libraryService.scrobble(songId: songId, submission: true)
        }
        Task { [listenBrainzService] in
            await listenBrainzService.notifyScrobbleThreshold(song: song, startDate: startDate)
        }
    }

    func cancelPendingCacheDownload() {
        cacheDownloadTask?.cancel()
        cacheDownloadTask = nil
    }

    // MARK: - Play-time accumulator

    func finalizePlaySegment() {
        guard let start = currentPlaySegmentStart else { return }
        accumulatedPlayedSeconds += Date().timeIntervalSince(start)
        currentPlaySegmentStart = nil
    }

    func resetTrackAccumulator(isPlaying: Bool) {
        accumulatedPlayedSeconds = 0
        trackPlayStartDate = Date()
        currentPlaySegmentStart = isPlaying ? Date() : nil
        detector.reset()
    }

    // MARK: - Stats recording

    func recordCurrentTrackPlayback(
        trigger: String = "unknown",
        overridingTrack: DisplayableSong? = nil
    ) async {
        guard Self.isListeningHistoryEnabled else { return }
        // Capture the outgoing counters before any suspension or track publication.
        let startDate = trackPlayStartDate
        let completed = wasTrackCompletedNaturally
        let segmentContrib = currentPlaySegmentStart.map { Date().timeIntervalSince($0) } ?? 0
        let durationListened = accumulatedPlayedSeconds + segmentContrib
        let recordedTrack: DisplayableSong?
        if let overridingTrack {
            recordedTrack = overridingTrack
        } else {
            recordedTrack = await MainActor.run { state.currentTrack }
        }
        guard let song = recordedTrack,
              let startDate else { return }
        guard let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else { return }

        guard durationListened >= 30 else {
            Logger.player.debug("[STATS] Skip — durationListened=\(durationListened)s < 30s")
            return
        }

        let trackDuration = song.duration
        let dto = PlaybackEventDTO(
            trackId: song.id,
            trackTitle: song.title,
            albumId: song.albumId,
            albumTitle: song.albumName,
            artistId: song.artistId,
            artistName: song.artist ?? "",
            genre: song.genre,
            timestamp: startDate,
            durationListened: durationListened,
            trackDuration: trackDuration,
            wasCompleted: completed,
            serverId: serverId.uuidString
        )
        // Persistence is ordered, but no longer holds up audio startup. The immutable DTO
        // keeps delayed writes attributed to the outgoing song, never the newly visible one.
        let previousWrite = historyWriteTask
        historyWriteTask = Task { [statsService] in
            await previousWrite?.value
            await statsService.recordPlayback(dto, trigger: trigger)
        }
    }

    // MARK: - Cache download helpers

    func downloadAndCache(
        songId: String,
        serverId: UUID,
        streamURL: URL,
        customHeaders: [String: String],
        using session: URLSession
    ) async throws {
        var request = URLRequest(url: streamURL)
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct CacheDownloadError: Error, Sendable { let statusCode: Int }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CacheDownloadError(statusCode: code)
        }

        try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: songId, logger: Logger.cache)

        try Task.checkCancellation()
        let ext = streamURL.pathExtension
        let mimeType = response.mimeType ?? (ext.isEmpty ? "audio/mpeg" : "audio/\(ext)")

        _ = try await cacheService.store(
            fileAt: tempURL,
            forSongId: songId,
            serverId: serverId,
            mimeType: mimeType
        )

        Logger.player.info("Cached '\(songId, privacy: .public)'")
    }
}
