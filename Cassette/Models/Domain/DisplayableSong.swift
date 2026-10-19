// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Unified song model for display and playback in Cassette.
///
/// Constructed from either a SwiftSonic `Song` (online) or a `DownloadedTrack` (offline).
/// PlayerService, SongRow, and all detail ViewModels work exclusively with this type —
/// SwiftSonic types are DTOs consumed at the API boundary only.
nonisolated struct DisplayableSong: Identifiable, Hashable, Sendable, Codable {
    /// Large API lists are value types; prepare them off the UI executor and publish once.
    /// Queue metadata stays complete, while audio preparation remains limited to the next item.
    static func prepare(
        _ entries: [Song],
        downloadedIDs: Set<String>,
        fallbackCoverArtID: String? = nil,
        sortedBy areInIncreasingOrder: (@Sendable (DisplayableSong, DisplayableSong) -> Bool)? = nil
    ) async throws -> [DisplayableSong] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            var result: [DisplayableSong] = []
            result.reserveCapacity(entries.count)
            for (index, song) in entries.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                result.append(DisplayableSong(from: song, isDownloaded: downloadedIDs.contains(song.id))
                    .withFallbackCoverArtID(fallbackCoverArtID))
            }
            if let areInIncreasingOrder { result.sort(by: areInIncreasingOrder) }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    let id: String
    let title: String
    let artist: String?
    let albumId: String?
    let albumName: String?
    let artistId: String?
    let genre: String?
    let duration: TimeInterval
    let trackNumber: Int?
    /// OpenSubsonic disc number (1-based). Nil when the server omits it.
    let discNumber: Int?
    var isDownloaded: Bool
    private(set) var coverArtId: String?
    let audioFormat: String?
    let contentType: String?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    /// OpenSubsonic comment — used to detect Dolby Atmos tags when channelCount is 2 (JOC).
    let comment: String?
    /// OpenSubsonic content advisory (`explicit`, `notExplicit`, `edited`) or a
    /// server-provided display value such as `E` / `19`.
    let explicitStatus: String?
    let replayGainTrackGain: Double?
    let replayGainTrackPeak: Double?
    let replayGainAlbumGain: Double?
    let replayGainAlbumPeak: Double?
    /// OpenSubsonic: always added to the selected mode's gain when present.
    let replayGainBaseGain: Double?
    /// OpenSubsonic: used as fallback when the selected mode's gain is absent.
    let replayGainFallbackGain: Double?
    /// Primary ISRC when the server provides one (Music Haptics / Now Playing).
    let isrc: String?
    /// OpenSubsonic song musicBrainzId (recording identity); optional for old persisted queues.
    let musicBrainzRecordingID: String?
    /// Local download provenance. false means a deliberate stereo/lossy conversion.
    let isOriginalAudio: Bool?
    /// Composer display string (OpenSubsonic).
    let displayComposer: String?
    /// Classical work name (OpenSubsonic `works`).
    let workName: String?
    /// Classical movement label, e.g. `"II. Andante"` (OpenSubsonic `movements`).
    let movementLabel: String?

    /// Server payloads occasionally contain an empty/whitespace `coverArt` value.
    /// Treat it as absent so every surface can reuse album artwork before falling back
    /// to a song identifier when no album is known.
    var explicitCoverArtId: String? {
        guard let value = coverArtId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    var effectiveCoverArtId: String {
        explicitCoverArtId ?? albumId.flatMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } ?? id
    }

    /// Missing track artwork may reuse known album metadata. Explicit alternate covers win.
    func withFallbackCoverArtID(_ albumCoverID: String?) -> Self {
        guard explicitCoverArtId == nil,
              let cover = albumCoverID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cover.isEmpty else { return self }
        var result = self
        result.coverArtId = cover
        return result
    }

    func showsArtist(inAlbumBy albumArtist: String?) -> Bool {
        guard let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else { return false }
        guard let albumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty else { return true }
        return artist.compare(albumArtist, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
    }

    /// Compact classical subtitle for lists / player (`Work · Movement`).
    var classicalSubtitle: String? {
        switch (workName, movementLabel) {
        case let (work?, movement?):
            return "\(work) · \(movement)"
        case let (work?, nil):
            return work
        case let (nil, movement?):
            return movement
        case (nil, nil):
            return nil
        }
    }

    nonisolated init(
        id: String,
        title: String,
        artist: String? = nil,
        albumId: String? = nil,
        albumName: String? = nil,
        artistId: String? = nil,
        genre: String? = nil,
        duration: TimeInterval = 0,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        isDownloaded: Bool = false,
        coverArtId: String? = nil,
        audioFormat: String? = nil,
        contentType: String? = nil,
        bitRate: Int? = nil,
        bitDepth: Int? = nil,
        samplingRate: Int? = nil,
        channelCount: Int? = nil,
        comment: String? = nil,
        explicitStatus: String? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil,
        replayGainBaseGain: Double? = nil,
        replayGainFallbackGain: Double? = nil,
        isrc: String? = nil,
        musicBrainzRecordingID: String? = nil,
        isOriginalAudio: Bool? = nil,
        displayComposer: String? = nil,
        workName: String? = nil,
        movementLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumId = albumId
        self.albumName = albumName
        self.artistId = artistId
        self.genre = genre
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isDownloaded = isDownloaded
        self.coverArtId = coverArtId
        self.audioFormat = audioFormat
        self.contentType = contentType
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.samplingRate = samplingRate
        self.channelCount = channelCount
        self.comment = comment
        self.explicitStatus = explicitStatus
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.replayGainBaseGain = replayGainBaseGain
        self.replayGainFallbackGain = replayGainFallbackGain
        self.isrc = isrc
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.isOriginalAudio = isOriginalAudio
        self.displayComposer = displayComposer
        self.workName = workName
        self.movementLabel = movementLabel
    }
}

extension DisplayableSong {
    nonisolated init(from song: Song, isDownloaded: Bool = false) {
        self.id = song.id
        self.title = song.title
        self.artist = song.artist
        self.albumId = song.albumId
        self.albumName = song.album
        self.artistId = song.artistId
        self.genre = song.genres?.first?.name ?? song.genre
        self.duration = song.duration.map(TimeInterval.init) ?? 0
        self.trackNumber = song.track
        self.discNumber = song.discNumber
        self.isDownloaded = isDownloaded
        self.coverArtId = song.coverArt
        self.audioFormat = song.suffix?.uppercased()
        self.contentType = song.contentType
        self.bitRate = song.bitRate
        self.bitDepth = song.bitDepth
        self.samplingRate = song.samplingRate
        self.channelCount = song.channelCount
        self.comment = song.comment
        self.explicitStatus = song.explicitStatus
        self.replayGainTrackGain = song.replayGain?.trackGain
        self.replayGainTrackPeak = song.replayGain?.trackPeak
        self.replayGainAlbumGain = song.replayGain?.albumGain
        self.replayGainAlbumPeak = song.replayGain?.albumPeak
        self.replayGainBaseGain = song.replayGain?.baseGain
        self.replayGainFallbackGain = song.replayGain?.fallbackGain
        self.isrc = song.isrc?.first
        self.musicBrainzRecordingID = song.musicBrainzId
        self.isOriginalAudio = nil
        self.displayComposer = song.displayComposer
        self.workName = song.works?.first?.name
        self.movementLabel = song.movements?.first?.displayLabel
    }

    /// Read on the owning ModelContext's executor; only the value snapshot crosses actors.
    nonisolated
    init(from track: DownloadedTrack) {
        self.id = track.songId
        self.title = track.title
        self.artist = track.artist
        self.albumId = track.albumId
        self.albumName = track.album
        self.artistId = track.artistId
        self.genre = track.genre
        self.duration = track.durationSeconds.map(TimeInterval.init) ?? 0
        self.trackNumber = track.trackNumber
        self.discNumber = track.discNumber
        self.isDownloaded = true
        self.coverArtId = track.coverArtId
        self.audioFormat = track.suffix?.uppercased()
        self.contentType = track.mimeType
        self.bitRate = track.bitRate
        self.bitDepth = track.bitDepth
        self.samplingRate = track.samplingRate
        self.channelCount = track.channelCount
        self.comment = track.comment
        self.explicitStatus = track.explicitStatus
        self.replayGainTrackGain = track.replayGainTrackGain
        self.replayGainTrackPeak = track.replayGainTrackPeak
        self.replayGainAlbumGain = track.replayGainAlbumGain
        self.replayGainAlbumPeak = track.replayGainAlbumPeak
        self.replayGainBaseGain = track.replayGainBaseGain
        self.replayGainFallbackGain = track.replayGainFallbackGain
        self.isrc = track.isrc
        self.musicBrainzRecordingID = track.musicBrainzID
        self.isOriginalAudio = track.isOriginalAudio
        self.displayComposer = nil
        self.workName = nil
        self.movementLabel = nil
    }

    /// A copy with `isDownloaded` flipped — the 16 fields are otherwise identical. Rebuilding it by hand (as 10
    /// sites did) risks silently dropping a newly-added optional field; this can't.
    func withDownloaded(_ flag: Bool) -> DisplayableSong {
        var copy = self
        copy.isDownloaded = flag
        return copy
    }

    /// Minimal SwiftSonic `Song` for DownloadService / playlist APIs that still take the DTO.
    func asSong() -> Song {
        Song(
            id: id,
            title: title,
            parent: nil,
            isDir: false,
            album: albumName,
            artist: artist,
            track: trackNumber,
            year: nil,
            genre: genre,
            coverArt: coverArtId,
            size: nil,
            contentType: contentType,
            suffix: audioFormat?.lowercased(),
            transcodedContentType: nil,
            transcodedSuffix: nil,
            duration: duration > 0 ? Int(duration) : nil,
            bitRate: bitRate,
            path: nil,
            isVideo: false,
            userRating: nil,
            averageRating: nil,
            playCount: nil,
            discNumber: discNumber,
            created: nil,
            starred: nil,
            albumId: albumId,
            artistId: artistId,
            type: nil,
            comment: comment,
            musicBrainzId: musicBrainzRecordingID,
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            channelCount: channelCount,
            explicitStatus: explicitStatus,
            works: workName.map { [Work(name: $0)] },
            movements: movementLabel.map { [Movement(name: $0)] }
        )
    }

    /// Apple Music presents explicit content as `19` in Korean and `E` in other locales.
    /// Literal server values are preserved so a server that already supplies either badge wins.
    func contentAdvisoryLabel(locale: Locale = .current) -> String? {
        guard let raw = explicitStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized == "notexplicit" || normalized == "edited" || normalized == "clean" {
            return nil
        }
        if normalized.contains("19") { return "19" }
        if normalized == "e" { return "E" }
        if normalized == "explicit" || normalized == "adult" {
            return locale.language.languageCode?.identifier == "ko" ? "19" : "E"
        }
        return nil
    }
}
