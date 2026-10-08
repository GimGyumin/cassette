// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

private nonisolated struct JellyfinOriginalDownloadSource: Sendable {
    let url: URL
    let expectedSize: Int64?
    let container: String?
}

actor DownloadService: DownloadServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let mediaIdentityService: MediaIdentityService?
    private let jellyfinService: JellyfinService?
    private let downloadsDirectory: URL
    private let coverArtsDirectory: URL
    private var progressContinuation: AsyncStream<[DownloadProgress]>.Continuation?
    /// Keyed by "songId::serverId" to allow per-track cancellation.
    private var inFlightTasks: [String: Task<Void, Error>] = [:]
    /// Cover requests are shared by every track that references the same artwork ID. Album
    /// downloads run several audio transfers at once, so a disk-only existence check can race
    /// and issue the same artwork request multiple times before the first write finishes.
    private var inFlightCoverTasks: [String: Task<Void, Error>] = [:]
    private var activeAlbumDownloads: Set<String> = []
    private var activePlaylistDownloads: Set<String> = []
    private let toastService: ToastService
    /// Small cover fetches stay on a foreground session (background sessions don't support data tasks).
    private let coverSession: URLSession
    #if os(macOS)
    /// macOS keeps a long-lived foreground media session (no background-session relaunch path).
    private let mediaSession: URLSession
    #endif

    nonisolated let progressStream: AsyncStream<[DownloadProgress]>

    init(
        serverService: any ServerServiceProtocol,
        modelContainer: ModelContainer,
        toastService: ToastService,
        mediaIdentityService: MediaIdentityService? = nil,
        jellyfinService: JellyfinService? = nil
    ) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.toastService = toastService
        self.mediaIdentityService = mediaIdentityService
        self.jellyfinService = jellyfinService

        let coverConfig = URLSessionConfiguration.default
        coverConfig.timeoutIntervalForRequest = 60
        coverConfig.timeoutIntervalForResource = 120
        self.coverSession = URLSession(configuration: coverConfig)
        #if os(macOS)
        let mediaConfig = URLSessionConfiguration.default
        // Request idle timeout can stay modest; the full-file budget must not.
        mediaConfig.timeoutIntervalForRequest = 60
        mediaConfig.timeoutIntervalForResource = 600
        self.mediaSession = URLSession(configuration: mediaConfig)
        #else
        // Warm the shared background media session so suspended downloads keep running.
        _ = CassetteBackgroundDownloads.shared
        #endif

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("app.cassette", isDirectory: true)
        self.downloadsDirectory = base.appendingPathComponent("downloads", isDirectory: true)
        self.coverArtsDirectory = base.appendingPathComponent("coverarts", isDirectory: true)

        // AsyncStream.init closure is called synchronously — cont is guaranteed set before init returns.
        var cont: AsyncStream<[DownloadProgress]>.Continuation!
        progressStream = AsyncStream<[DownloadProgress]>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        progressContinuation = cont
    }

    // MARK: - Lookup

    func downloadedURL(forSongId songId: String, serverId: UUID) async -> URL? {
        let candidates = await MainActor.run {
            mediaIdentityService?.candidateRemoteIDs(for: songId, serverId: serverId, entityType: .song) ?? [songId]
        }
        let candidateSet = Set(candidates)
        let entry: (filePath: String, fileSize: Int64)? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let descriptor = FetchDescriptor<DownloadedTrack>(predicate: #Predicate { $0.serverId == sid })
            guard let track = try? context.fetch(descriptor).first(where: {
                candidateSet.contains($0.songId)
                    || ($0.currentRemoteID.map(candidateSet.contains) ?? false)
                    || !candidateSet.isDisjoint(with: $0.legacyRemoteIDs ?? [])
            }) else { return nil }
            // Older downloads kept source surround metadata even after lossy transcoding.
            // Keep that file on disk, but allow a new original download to replace it.
            let mime = track.mimeType.lowercased()
            if (track.channelCount ?? 0) > 2,
               !["mp3", "opus", "ogg", "oga"].contains(track.suffix?.lowercased() ?? ""),
               ["audio/mpeg", "audio/mp3", "audio/opus", "audio/ogg"].contains(mime) {
                return nil
            }
            return (track.filePath, track.fileSize)
        }
        guard let entry else { return nil }
        let url = downloadsDirectory.appendingPathComponent(entry.filePath)
        // A missing, empty, or size-mismatched file must fall through to cache/stream —
        // never hand a broken local file to the player. The file is NOT deleted here
        // (permanent downloads are user data); the record's size 0 means a legacy entry
        // whose size read failed at write time, where only non-emptiness can be checked.
        let diskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard diskSize > 0, entry.fileSize == 0 || diskSize == entry.fileSize else {
            Logger.download.warning("Downloaded track record exists but file missing or invalid (disk \(diskSize) bytes, record \(entry.fileSize)): \(entry.filePath, privacy: .public)")
            return nil
        }
        return url
    }

    func isDownloaded(songId: String, serverId: UUID) async -> Bool {
        await downloadedURL(forSongId: songId, serverId: serverId) != nil
    }

    func downloadedSongIds(serverId: UUID) async -> Set<String> {
        let rawIDs: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let descriptor = FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid }
            )
            let tracks = (try? context.fetch(descriptor)) ?? []
            return tracks.flatMap { track in
                [track.songId, track.currentRemoteID].compactMap { $0 } + (track.legacyRemoteIDs ?? [])
            }
        }
        var result = Set(rawIDs)
        for id in rawIDs {
            let aliases = await MainActor.run {
                mediaIdentityService?.candidateRemoteIDs(for: id, serverId: serverId, entityType: .song) ?? [id]
            }
            result.formUnion(aliases)
        }
        return result
    }

    func localCoverArtURL(forId coverArtId: String) async -> URL? {
        let parts = coverArtId.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let baseID = String(parts[0])
        let suffix = parts.count == 2 ? "@\(parts[1])" : ""
        let candidates = await MainActor.run {
            guard let serverID = serverService.state.activeServer?.id else { return [baseID] }
            return mediaIdentityService?.candidateRemoteIDs(
                for: baseID, serverId: serverID, entityType: .coverArt
            ) ?? [baseID]
        }
        let suffixes = suffix.isEmpty ? ["@original-v1", ""] : [suffix]
        for preferredSuffix in suffixes {
            for candidate in candidates {
                let url = coverArtsDirectory.appendingPathComponent(candidate + preferredSuffix)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    func persistCover(_ data: Data, forId coverArtId: String) async {
        guard await MainActor.run(body: {
            serverService.state.activeServer != nil && !serverService.state.isSigningOut
        }) else { return }
        let url = coverArtsDirectory.appendingPathComponent(coverArtId)
        Logger.download.debug("persistCover id='\(coverArtId, privacy: .public)' path='\(url.path, privacy: .public)' bytes=\(data.count, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.download.debug("Failed to persist cover '\(coverArtId, privacy: .public)': \(error, privacy: .public)")
        }
    }

    func removeCover(forId coverArtId: String) async {
        let url = coverArtsDirectory.appendingPathComponent(coverArtId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.download.debug("Failed to remove cover '\(coverArtId, privacy: .public)': \(error, privacy: .public)")
        }
    }

    @discardableResult
    func garbageCollectOrphanedCovers(referencedIds: Set<String>) async -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: coverArtsDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var retainedIDs = referencedIds
        if let serverID = await MainActor.run(body: { serverService.state.activeServer?.id }) {
            for id in referencedIds {
                let candidates = await MainActor.run {
                    mediaIdentityService?.candidateRemoteIDs(
                        for: id,
                        serverId: serverID,
                        entityType: .coverArt
                    ) ?? [id]
                }
                retainedIDs.formUnion(candidates)
            }
        }
        var deletedCount = 0
        for fileURL in entries {
            let filename = fileURL.lastPathComponent
            // Skip tier-suffixed files (id@thumb, id@hero) — those are streaming cache
            // managed by ArtworkImageCache's own eviction, not offline-download GC.
            guard !filename.contains("@") else { continue }
            let coverArtId = filename
            if !retainedIDs.contains(coverArtId) {
                do {
                    try fm.removeItem(at: fileURL)
                } catch {
                    Logger.download.debug("DownloadService: garbageCollect removeItem failed — \(error)")
                }
                deletedCount += 1
            }
        }
        if deletedCount > 0 {
            Logger.download.info("Garbage collected \(deletedCount) orphaned cover(s).")
        }
        return deletedCount
    }

    func localAlbumData(albumId: String, serverId: UUID) async -> LocalAlbumData? {
        let albumIDs = await MainActor.run {
            Set(mediaIdentityService?.candidateRemoteIDs(
                for: albumId,
                serverId: serverId,
                entityType: .album
            ) ?? [albumId])
        }
        return await MainActor.run {
            let context = ModelContext(modelContainer)
            // Tracks are the primary source — present whether the album was downloaded
            // directly or via a playlist download that never created a DownloadedAlbum record.
            let sid = serverId
            let albumTracks = ((try? context.fetch(FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []).filter { track in
                track.albumId.map(albumIDs.contains) ?? false
            }
                .sorted { ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max) }
            guard !albumTracks.isEmpty else { return nil }
            let first = albumTracks[0]
            // DownloadedAlbum record may exist for richer metadata (direct album downloads).
            let albumRecord = try? context.fetch(FetchDescriptor<DownloadedAlbum>(
                predicate: #Predicate { $0.serverId == sid }
            )).first(where: { albumIDs.contains($0.albumId) })
            let songs = albumTracks.map { DisplayableSong(from: $0) }
            return LocalAlbumData(
                albumId: albumId,
                albumName: albumRecord?.name ?? first.album ?? albumId,
                artistName: albumRecord?.artist ?? first.artist,
                coverArtId: albumRecord?.coverArtId ?? first.coverArtId,
                songs: songs
            )
        }
    }

    func localPlaylistData(playlistId: String, serverId: UUID) async -> LocalPlaylistData? {
        let playlistIDs = await MainActor.run {
            Set(mediaIdentityService?.candidateRemoteIDs(
                for: playlistId,
                serverId: serverId,
                entityType: .playlist
            ) ?? [playlistId])
        }
        return await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            guard let playlist = try? context.fetch(FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.serverId == sid }
            )).first(where: { playlistIDs.contains($0.playlistId) }) else { return nil }
            // serverId-scoped lookup table — O(1) per id and avoids matching a track that was
            // re-downloaded under a different server with a colliding songId.
            let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let songs = playlist.songIds.compactMap { storedID in
                let candidates = Set(mediaIdentityService?.candidateRemoteIDs(
                    for: storedID,
                    serverId: serverId,
                    entityType: .song
                ) ?? [storedID])
                return tracks.first {
                    candidates.contains($0.songId)
                        || ($0.currentRemoteID.map(candidates.contains) ?? false)
                        || !candidates.isDisjoint(with: Set($0.legacyRemoteIDs ?? []))
                }
            }.map { DisplayableSong(from: $0) }
            return LocalPlaylistData(playlistId: playlist.playlistId, name: playlist.name, coverArtId: playlist.coverArtId, songs: songs)
        }
    }

    func backfillPlaylistSongIds(playlistId: String, serverId: UUID, orderedSongIds: [String]) async {
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let pid = playlistId
            let sid = serverId
            var playlistDescriptor = FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.playlistId == pid && $0.serverId == sid }
            )
            playlistDescriptor.fetchLimit = 1
            // Only repair records that are actually missing their order. DownloadedTrack carries
            // no playlist link, so membership cannot be recovered from disk alone — the order must
            // come from the authoritative API list, intersected with what is actually downloaded.
            guard let record = try? context.fetch(playlistDescriptor).first,
                  record.songIds.isEmpty else { return }
            let downloaded = Set(
                ((try? context.fetch(FetchDescriptor<DownloadedTrack>(
                    predicate: #Predicate { $0.serverId == sid }
                ))) ?? [])
                    .map(\.songId)
            )
            let repaired = orderedSongIds.filter { downloaded.contains($0) }
            guard !repaired.isEmpty else { return }
            record.songIds = repaired
            do {
                try context.save()
                Logger.download.info("Back-filled \(repaired.count, privacy: .public) songId(s) for playlist '\(playlistId, privacy: .public)'")
            } catch {
                Logger.download.debug("DownloadService: songIds back-fill save failed — \(error)")
            }
        }
    }

    // MARK: - Single track download

    func download(song: Song, serverId: UUID) async throws {
        try await downloadAudio(song: song, serverId: serverId, albumCoverArtID: nil)
        let songCoverArtID = song.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCoverArtID = songCoverArtID.flatMap { $0.isEmpty ? nil : $0 } ?? song.id
        do {
            try await _downloadCoverArt(id: resolvedCoverArtID)
        } catch {
            Logger.download.error("Cover art download failed for '\(song.id, privacy: .public)': \(error, privacy: .public)")
        }
    }

    /// Downloads and records only the audio payload. Album downloads call this path so artwork
    /// can be planned once for the whole album: the shared album cover is fetched once and only
    /// tracks with a different cover-art ID add another request.
    private func downloadAudio(song: Song, serverId: UUID, albumCoverArtID: String?) async throws {
        guard await !isDownloaded(songId: song.id, serverId: serverId) else {
            Logger.download.debug("Song '\(song.id, privacy: .public)' already downloaded — skipping.")
            return
        }

        let key = taskKey(songId: song.id, serverId: serverId)
        // Join an in-flight download instead of returning success while the file
        // is still missing — that made the first tap look like a no-op/failure.
        if let existing = inFlightTasks[key] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            try await self._downloadSong(
                song,
                serverId: serverId,
                key: key,
                albumCoverArtID: albumCoverArtID
            )
        }
        inFlightTasks[key] = task
        try await task.value
    }

    private func _downloadSong(
        _ song: Song,
        serverId: UUID,
        key: String,
        albumCoverArtID: String?
    ) async throws {
        defer { inFlightTasks.removeValue(forKey: key) }

        let creds = try await serverService.activeCredentials()
        let client = try await serverService.makeSwiftSonicClient()
        guard await MainActor.run(body: { serverService.state.activeServer?.id == serverId }) else {
            throw CancellationError()
        }
        let formatRaw = UserDefaults.standard.string(forKey: "cassette.streaming.download")
        let preserveBitstream = AudioQualityClassifier.shouldSkipTranscoding(DisplayableSong(from: song))
        let requestedFormat: CacheFormat = preserveBitstream ? .flacOriginal : (CacheFormat(rawValue: formatRaw ?? "") ?? .matchStream)
        var mediaURL: URL?
        var expectedOriginalSize: Int64?
        var originalContainer: String?
        switch requestedFormat {
        case .flacOriginal:
            if let jellyfinService,
               let jellyfinID = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: song.id) {
                let source = try? await jellyfinService.perform(feature: .originalFile) { client -> JellyfinOriginalDownloadSource? in
                    let playbackInfo = try await client.playbackInfo(itemID: jellyfinID)
                    guard let url = client.downloadURL(itemID: jellyfinID)
                        ?? client.originalFileURL(itemID: jellyfinID) else { return nil }
                    return JellyfinOriginalDownloadSource(
                        url: url,
                        expectedSize: playbackInfo.mediaSources.first?.containerSize,
                        container: playbackInfo.mediaSources.first?.container
                    )
                }
                mediaURL = source?.url
                expectedOriginalSize = source?.expectedSize
                originalContainer = source?.container
            } else {
                mediaURL = nil
            }
            if mediaURL == nil {
                mediaURL = client.streamURL(id: song.id, format: "raw")
            }
        case .matchStream:
            mediaURL = client.streamURL(id: song.id, format: "raw")
        default:
            mediaURL = client.streamURL(
                id: song.id,
                maxBitRate: requestedFormat.subsonicMaxBitRate,
                format: requestedFormat.subsonicFormat
            )
        }
        guard let mediaURL else {
            throw CassetteError.mediaNotFound(songId: song.id)
        }

        var request = URLRequest(url: mediaURL)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 0, totalBytes: nil, receivedBytes: 0))

        let progressSink = progressContinuation
        let progressSongId = song.id
        let progressServerId = serverId
        let (tempURL, response): (URL, URLResponse)
        #if os(iOS)
        (tempURL, response) = try await CassetteBackgroundDownloads.shared.download(
            request: request,
            clientKey: key,
            onProgress: { received, total in
                let fraction: Double
                if let total, total > 0 {
                    fraction = min(1.0, Double(received) / Double(total))
                } else {
                    fraction = 0
                }
                progressSink?.yield([
                    DownloadProgress(
                        songId: progressSongId,
                        serverId: progressServerId,
                        progress: fraction,
                        totalBytes: total,
                        receivedBytes: received
                    )
                ])
            }
        )
        #else
        (tempURL, response) = try await mediaSession.download(for: request)
        #endif
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            struct HTTPError: Error & Sendable { let statusCode: Int }
            throw CassetteError.downloadFailed(songId: song.id, underlying: HTTPError(statusCode: code))
        }

        // Never save a poisoned payload as a permanent download (Subsonic error-as-200
        // envelope, empty or truncated body) — unlike the cache it is never evicted,
        // so a broken file would play as silence forever.
        do {
            try AudioResponseValidator.validate(fileAt: tempURL, response: response, songId: song.id, logger: Logger.download)
        } catch {
            throw CassetteError.downloadFailed(songId: song.id, underlying: error)
        }

        if let expectedOriginalSize, expectedOriginalSize > 0 {
            let receivedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            guard receivedSize == expectedOriginalSize else {
                struct OriginalSizeMismatch: Error & Sendable {
                    let expected: Int64
                    let received: Int64
                }
                throw CassetteError.downloadFailed(
                    songId: song.id,
                    underlying: OriginalSizeMismatch(expected: expectedOriginalSize, received: receivedSize)
                )
            }
        }

        let mimeType = response.mimeType ?? "audio/mpeg"
        // Prefer the server-declared suffix (e.g. "mp3", "flac") over the MIME subtype.
        // audio/mpeg → "mpeg" which AVPlayer maps to a video UTI, not public.mp3.
        let ext = requestedFormat.downloadFileExtension(
            mimeType: response.mimeType,
            originalSuffix: song.suffix ?? originalContainer
        )
        let relativePath = "\(serverId.uuidString)/\(song.id).\(ext)"
        let fileURL = downloadsDirectory.appendingPathComponent(relativePath)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        // Faststart-remux non-faststart m4a for AudioStreaming offline playback.
        // Skip Atmos / multichannel — remux can strip spatial bitstreams; those use AVPlayer.
        let skipRemux: Bool = {
            let probe = DisplayableSong(from: song)
            return AudioQualityClassifier.requiresSystemPlayer(probe)
        }()
        if !skipRemux, case .remuxed = await AudioFaststartRemuxer().remuxToFaststartIfNeeded(at: fileURL) {
            Logger.download.info("Faststart-remuxed m4a download '\(song.id, privacy: .public)'")
        } else if skipRemux {
            Logger.download.info("[SPATIAL] Skipping faststart remux for Dolby/multichannel '\(song.id, privacy: .public)'")
        }

        // Capture only Sendable values for the MainActor closure.
        let songId = song.id
        let albumId = song.albumId
        let artistId = song.artistId
        let title = song.title
        let artist = song.artist
        let album = song.album
        let genre = song.genres?.first?.name ?? song.genre
        let track = song.track
        let disc = song.discNumber
        let duration = song.duration
        let mediaPath = song.path
        let musicBrainzID = song.musicBrainzId
        let isrc = song.isrc?.first
        let coverArtId = song.coverArt ?? albumCoverArtID
        let isTranscoded = requestedFormat.subsonicMaxBitRate != nil
        let suffix = ext
        let bitRate = isTranscoded ? requestedFormat.subsonicMaxBitRate : song.bitRate
        let bitDepth = isTranscoded ? nil : song.bitDepth
        let samplingRate = isTranscoded ? nil : song.samplingRate
        let channelCount = isTranscoded ? nil : song.channelCount
        let comment = song.comment
        let explicitStatus = song.explicitStatus
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let rgTrackGain    = song.replayGain?.trackGain
        let rgTrackPeak    = song.replayGain?.trackPeak
        let rgAlbumGain    = song.replayGain?.albumGain
        let rgAlbumPeak    = song.replayGain?.albumPeak
        let rgBaseGain     = song.replayGain?.baseGain
        let rgFallbackGain = song.replayGain?.fallbackGain

        // Commit audio before fetching optional artwork so slow covers cannot hide a finished track.
        try await MainActor.run {
            guard serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut else { throw CancellationError() }
            let context = ModelContext(modelContainer)
            let stableID = mediaIdentityService?.observe(
                remoteID: songId,
                serverId: serverId,
                entityType: .song
            )
            let record = DownloadedTrack(
                localStableID: stableID,
                songId: songId,
                serverId: serverId,
                albumId: albumId,
                filePath: relativePath,
                fileSize: fileSize,
                mimeType: mimeType,
                title: title,
                artist: artist,
                artistId: artistId,
                album: album,
                trackNumber: track,
                discNumber: disc,
                durationSeconds: duration,
                mediaPath: mediaPath,
                musicBrainzID: musicBrainzID,
                isrc: isrc,
                coverArtId: coverArtId,
                suffix: suffix,
                genre: genre,
                bitRate: bitRate,
                bitDepth: bitDepth,
                samplingRate: samplingRate,
                channelCount: channelCount,
                comment: comment,
                explicitStatus: explicitStatus,
                replayGainTrackGain: rgTrackGain,
                replayGainTrackPeak: rgTrackPeak,
                replayGainAlbumGain: rgAlbumGain,
                replayGainAlbumPeak: rgAlbumPeak,
                replayGainBaseGain: rgBaseGain,
                replayGainFallbackGain: rgFallbackGain
            )
            let previous = try context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.songId == songId && $0.serverId == serverId
            }))
            for old in previous { context.delete(old) }
            context.insert(record)
            do {
                try context.save()
            } catch {
                context.rollback()
                try? FileManager.default.removeItem(at: fileURL)
                Logger.download.error("DownloadService: track record save failed for '\(songId, privacy: .public)' — \(error)")
                throw error
            }
        }

        emit(progress: DownloadProgress(songId: song.id, serverId: serverId, progress: 1.0, totalBytes: fileSize, receivedBytes: fileSize))
        Logger.download.info("Downloaded '\(song.id, privacy: .public)' (\(fileSize) bytes)")
    }

    // MARK: - Album download

    func download(album: AlbumID3, serverId: UUID) async throws {
        guard let songs = album.song else { return }
        activeAlbumDownloads.insert(album.id)
        defer { activeAlbumDownloads.remove(album.id) }
        let total = songs.count
        var succeeded = 0
        let aid = album.id
        let albumCoverArtID = album.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbumCoverArtID = albumCoverArtID?.isEmpty == false ? albumCoverArtID : nil

        let maxConcurrent = 3
        await withTaskGroup(of: Bool.self) { group in
            var iterator = songs.makeIterator()

            for _ in 0..<maxConcurrent {
                guard let song = iterator.next() else { break }
                group.addTask {
                    do {
                        try await self.downloadAudio(
                            song: song,
                            serverId: serverId,
                            albumCoverArtID: normalizedAlbumCoverArtID
                        )
                        return true
                    } catch {
                        Logger.download.error("Failed song '\(song.id, privacy: .public)' in album '\(aid, privacy: .public)': \(error, privacy: .public)")
                        return false
                    }
                }
            }

            for await didSucceed in group {
                if didSucceed { succeeded += 1 }
                if let song = iterator.next() {
                    group.addTask {
                        do {
                            try await self.downloadAudio(
                                song: song,
                                serverId: serverId,
                                albumCoverArtID: normalizedAlbumCoverArtID
                            )
                            return true
                        } catch {
                            Logger.download.error("Failed song '\(song.id, privacy: .public)' in album '\(aid, privacy: .public)': \(error, privacy: .public)")
                            return false
                        }
                    }
                }
            }
        }

        var localCoverPath: String? = nil
        let coverArtIDs = Self.albumCoverArtIDs(
            albumCoverArtID: normalizedAlbumCoverArtID,
            songCoverArtIDs: songs.map(\.coverArt)
        )
        for coverArtId in coverArtIDs {
            do {
                try await _downloadCoverArt(id: coverArtId)
                if coverArtId == normalizedAlbumCoverArtID { localCoverPath = coverArtId }
            } catch {
                Logger.download.error("Cover art download failed for album '\(album.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }

        let albumId = album.id
        let albumName = album.name
        let albumArtist = album.artist
        let coverArt = album.coverArt
        let tracksSucceeded = succeeded
        let totalTracks = total
        let coverPath = localCoverPath

        await MainActor.run {
            guard serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut else { return }
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate {
                $0.albumId == albumId && $0.serverId == sid
            })))?.first

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedAlbum(
                    albumId: albumId,
                    serverId: serverId,
                    name: albumName,
                    artist: albumArtist,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: album record save failed — \(error)")
            }
        }
        Logger.download.info("Album '\(album.id, privacy: .public)': \(succeeded)/\(total) tracks downloaded.")
        if succeeded == total, total > 0 {
            await toastService.showSuccess("\(album.name) downloaded")
        } else if succeeded == 0, total > 0 {
            await toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    // MARK: - Playlist download

    func download(playlist: PlaylistWithSongs, serverId: UUID) async throws {
        let songs = playlist.entry ?? []
        let total = songs.count
        let pid = playlist.id
        activePlaylistDownloads.insert(playlist.id)
        defer { activePlaylistDownloads.remove(playlist.id) }

        let maxConcurrent = 3
        await withTaskGroup(of: Void.self) { group in
            var iterator = songs.makeIterator()

            for _ in 0..<maxConcurrent {
                guard let song = iterator.next() else { break }
                group.addTask {
                    do {
                        try await self.download(song: song, serverId: serverId)
                    } catch {
                        Logger.download.error("Failed song '\(song.id, privacy: .public)' in playlist '\(pid, privacy: .public)': \(error, privacy: .public)")
                    }
                }
            }

            for await _ in group {
                if let song = iterator.next() {
                    group.addTask {
                        do {
                            try await self.download(song: song, serverId: serverId)
                        } catch {
                            Logger.download.error("Failed song '\(song.id, privacy: .public)' in playlist '\(pid, privacy: .public)': \(error, privacy: .public)")
                        }
                    }
                }
            }
        }

        let downloadedIds = await downloadedSongIds(serverId: serverId)
        let succeededIds = songs.filter { downloadedIds.contains($0.id) }.map(\.id)

        var localCoverPath: String? = nil
        if let coverArtId = playlist.coverArt {
            do {
                try await _downloadCoverArt(id: coverArtId)
                localCoverPath = coverArtId
            } catch {
                Logger.download.error("Cover art download failed for playlist '\(playlist.id, privacy: .public)' (coverArtId: \(coverArtId, privacy: .public)): \(error, privacy: .public)")
            }
        }

        let playlistId = playlist.id
        let playlistName = playlist.name
        let comment = playlist.comment
        let coverArt = playlist.coverArt
        let tracksSucceeded = succeededIds.count
        let totalTracks = total
        let ids = succeededIds
        let coverPath = localCoverPath

        await MainActor.run {
            guard serverService.state.activeServer?.id == serverId,
                  !serverService.state.isSigningOut else { return }
            let context = ModelContext(modelContainer)
            let sid = serverId
            let existing = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate {
                $0.playlistId == playlistId && $0.serverId == sid
            })))?.first

            if let existing {
                existing.tracksCount = tracksSucceeded
                existing.totalTracksCount = totalTracks
                existing.downloadedAt = Date()
                existing.songIds = ids
                if let coverPath { existing.localCoverArtPath = coverPath }
            } else {
                let record = DownloadedPlaylist(
                    playlistId: playlistId,
                    serverId: serverId,
                    name: playlistName,
                    comment: comment,
                    tracksCount: tracksSucceeded,
                    totalTracksCount: totalTracks,
                    coverArtId: coverArt,
                    localCoverArtPath: coverPath,
                    songIds: ids
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: playlist record save failed — \(error)")
            }
        }
        Logger.download.info("Playlist '\(playlist.id, privacy: .public)': \(tracksSucceeded)/\(total) tracks downloaded.")
        if tracksSucceeded == totalTracks, totalTracks > 0 {
            await toastService.showSuccess("\(playlist.name) downloaded")
        } else if tracksSucceeded == 0, totalTracks > 0 {
            await toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    func isDownloading(songId: String, serverId: UUID) async -> Bool {
        inFlightTasks[taskKey(songId: songId, serverId: serverId)] != nil
    }

    func isDownloadingAlbum(_ albumId: String) async -> Bool {
        activeAlbumDownloads.contains(albumId)
    }

    func isDownloadingPlaylist(_ playlistId: String) async -> Bool {
        activePlaylistDownloads.contains(playlistId)
    }

    // MARK: - Cancel

    func cancelAllDownloads() async {
        let tasks = inFlightTasks
        for (key, task) in tasks {
            task.cancel()
            #if os(iOS)
            CassetteBackgroundDownloads.shared.cancel(clientKey: key)
            #endif
        }
        for task in tasks.values { _ = await task.result }
        progressContinuation?.yield([])
    }

    func cancelDownload(songId: String, serverId: UUID) async {
        let key = taskKey(songId: songId, serverId: serverId)
        inFlightTasks[key]?.cancel()
        inFlightTasks.removeValue(forKey: key)
        #if os(iOS)
        CassetteBackgroundDownloads.shared.cancel(clientKey: key)
        #endif
    }

    // MARK: - Remove

    func remove(songId: String, serverId: UUID) async throws {
        let storedTrack: (filePath: String, albumId: String?)? = await MainActor.run {
            let context = ModelContext(modelContainer)
            let predicate = #Predicate<DownloadedTrack> { $0.songId == songId }
            let tracks = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
            return tracks.first(where: { $0.serverId == serverId }).map { ($0.filePath, $0.albumId) }
        }
        if let storedTrack {
            let fileURL = downloadsDirectory.appendingPathComponent(storedTrack.filePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let predicate = #Predicate<DownloadedTrack> { $0.songId == songId }
            let tracks = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
            tracks.filter { $0.serverId == serverId }.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: remove track save failed — \(error)")
            }
        }
        // Keep full-album metadata honest when a single track is removed from the storage screen.
        // Delete the album record when its final track disappears; otherwise update its count.
        if let albumId = storedTrack?.albumId {
            await MainActor.run {
                let context = ModelContext(modelContainer)
                let sid = serverId
                let aid = albumId
                let remaining = (try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                    $0.serverId == sid && $0.albumId == aid
                }))) ?? []
                let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate {
                    $0.serverId == sid && $0.albumId == aid
                }))) ?? []
                if remaining.isEmpty {
                    albums.forEach { context.delete($0) }
                } else {
                    albums.forEach { $0.tracksCount = remaining.count }
                }
                try? context.save()
            }
        }
        // Sync DownloadedPlaylist.songIds — remove this songId from any playlist that contains it.
        // Without this, the cold-start retry would re-download the song silently after removal.
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let playlists = (try? context.fetch(
                FetchDescriptor<DownloadedPlaylist>(predicate: #Predicate { $0.serverId == sid })
            )) ?? []
            var didMutate = false
            for playlist in playlists where playlist.songIds.contains(songId) {
                playlist.songIds.removeAll { $0 == songId }
                playlist.tracksCount = playlist.songIds.count
                didMutate = true
            }
            if didMutate {
                do {
                    try context.save()
                } catch {
                    Logger.download.debug("DownloadService: remove playlist sync save failed — \(error)")
                }
            }
        }
    }

    func remove(albumId: String, serverId: UUID) async throws {
        let songIds: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let aid = albumId
            return ((try? context.fetch(FetchDescriptor<DownloadedTrack>(predicate: #Predicate {
                $0.serverId == sid && $0.albumId == aid
            }))) ?? []).map(\.songId)
        }
        for songId in songIds {
            try? await remove(songId: songId, serverId: serverId)
        }
        await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let aid = albumId
            let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(predicate: #Predicate {
                $0.albumId == aid && $0.serverId == sid
            }))) ?? []
            albums.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: remove album save failed — \(error)")
            }
        }
    }

    func remove(playlistId: String, serverId: UUID) async throws {
        // Refcount-safe LOCAL purge (mirrors remove(albumId:)): delete the playlist record AND the track files it
        // owns — but KEEP any file still referenced by another downloaded playlist or a downloaded album, so a
        // song shared between two playlists survives until the LAST one is removed. Purely local: never touches
        // the server, so purging an orphan whose playlist is already gone is safe and idempotent.
        let songsToPurge: [String] = await MainActor.run {
            let context = ModelContext(modelContainer)
            let sid = serverId
            let allPlaylists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let mine = allPlaylists.filter { $0.playlistId == playlistId }
            let owned = Set(mine.flatMap { $0.songIds })
            // Songs still referenced by ANOTHER downloaded playlist on this server → keep their files.
            let sharedByOtherPlaylist = Set(
                allPlaylists.filter { $0.playlistId != playlistId }.flatMap { $0.songIds }
            )
            // Albums downloaded on this server → keep any of their tracks (don't break a co-downloaded album).
            let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let downloadedAlbumIds = Set(albums.map(\.albumId))
            let allTracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid }
            ))) ?? []
            let albumIdBySong = Dictionary(
                allTracks.filter { owned.contains($0.songId) }
                    .compactMap { track -> (String, String)? in
                        guard let albumId = track.albumId else { return nil }
                        return (track.songId, albumId)
                    },
                uniquingKeysWith: { first, _ in first }
            )
            let toPurge = owned.filter { songId in
                if sharedByOtherPlaylist.contains(songId) { return false }
                if let albumId = albumIdBySong[songId], downloadedAlbumIds.contains(albumId) { return false }
                return true
            }
            // Delete the playlist record FIRST so remove(songId:)'s playlist-sync is a no-op for it.
            mine.forEach { context.delete($0) }
            do {
                try context.save()
            } catch {
                Logger.download.debug("DownloadService: remove playlist save failed — \(error)")
            }
            return Array(toPurge)
        }
        // Delete the files + DownloadedTrack records for the non-shared songs (local + idempotent).
        for songId in songsToPurge {
            try? await remove(songId: songId, serverId: serverId)
        }
    }

    // MARK: - Helpers

    private func taskKey(songId: String, serverId: UUID) -> String {
        "\(songId)::\(serverId.uuidString)"
    }

    /// Returns one stable request per artwork identity, preserving album-first ordering. A track
    /// whose cover equals the album cover adds no work; only genuinely different track covers do.
    nonisolated static func albumCoverArtIDs(
        albumCoverArtID: String?,
        songCoverArtIDs: [String?]
    ) -> [String] {
        var seen = Set<String>()
        return ([albumCoverArtID] + songCoverArtIDs).compactMap { value in
            guard let value else { return nil }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }

    private func emit(progress: DownloadProgress) {
        progressContinuation?.yield([progress])
        if progress.progress >= 1 {
            Task { @MainActor in
                NotificationCenter.default.post(name: .cassetteDownloadCompleted, object: nil)
            }
        }
    }

    /// Downloads original bytes to `coverArtsDirectory/<id>@original-v1`, independently of streaming caches.
    /// Throws on network or write error — callers must catch and treat as best-effort.
    private func _downloadCoverArt(id: String) async throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let fileURL = coverArtsDirectory.appendingPathComponent(OriginalArtwork.storageID(normalizedID))
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.download.debug("Cover art '\(normalizedID, privacy: .public)' already on disk — skipping.")
            return
        }

        if let existing = inFlightCoverTasks[normalizedID] {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            try await self._fetchAndStoreCoverArt(id: normalizedID, fileURL: fileURL)
        }
        inFlightCoverTasks[normalizedID] = task
        defer { inFlightCoverTasks.removeValue(forKey: normalizedID) }
        try await task.value
    }

    private func _fetchAndStoreCoverArt(id: String, fileURL: URL) async throws {
        // Another completed request may have installed the file while this task waited to enter
        // the actor. Recheck immediately before performing network work.
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let creds = try await serverService.activeCredentials()
        let client = try await serverService.makeSwiftSonicClient()
        // Request the ORIGINAL (full-resolution) cover — no server-side `size` downscale —
        // so offline album art is stored at its highest quality.
        guard let artURL = client.coverArtURL(id: id, size: nil) else {
            throw CassetteError.mediaNotFound(songId: id)
        }

        var request = URLRequest(url: artURL)
        for (k, v) in creds.customHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await coverSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            struct HTTPError: Error & Sendable { let statusCode: Int }
            throw CassetteError.downloadFailed(songId: id, underlying: HTTPError(statusCode: code))
        }
        guard await Task.detached(priority: .utility, operation: {
            ArtworkImageCache.thumbnailImage(from: data, maxDimension: 8) != nil
        }).value else { throw URLError(.cannotDecodeContentData) }

        // Persist the original bytes verbatim — no JPEG re-encode, no low-resolution decode.
        try FileManager.default.createDirectory(at: coverArtsDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        await MainActor.run { NotificationCenter.default.post(name: OriginalArtwork.didInstall, object: id) }
        Logger.download.info("Cover art '\(id, privacy: .public)' downloaded (\(data.count) bytes, original)")
    }
}
