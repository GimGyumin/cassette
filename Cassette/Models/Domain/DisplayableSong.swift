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
    let coverArtId: String?
    let audioFormat: String?
    let contentType: String?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    /// OpenSubsonic comment — used to detect Dolby Atmos tags when channelCount is 2 (JOC).
    let comment: String?
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
    /// Composer display string (OpenSubsonic).
    let displayComposer: String?
    /// Classical work name (OpenSubsonic `works`).
    let workName: String?
    /// Classical movement label, e.g. `"II. Andante"` (OpenSubsonic `movements`).
    let movementLabel: String?

    /// Server payloads occasionally contain an empty/whitespace `coverArt` value.
    /// Treat it as absent so every playback surface can consistently fall back to the
    /// song identifier accepted by the Subsonic cover-art endpoint.
    var explicitCoverArtId: String? {
        guard let value = coverArtId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    var effectiveCoverArtId: String {
        explicitCoverArtId ?? id
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
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil,
        replayGainBaseGain: Double? = nil,
        replayGainFallbackGain: Double? = nil,
        isrc: String? = nil,
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
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.replayGainBaseGain = replayGainBaseGain
        self.replayGainFallbackGain = replayGainFallbackGain
        self.isrc = isrc
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
        self.replayGainTrackGain = song.replayGain?.trackGain
        self.replayGainTrackPeak = song.replayGain?.trackPeak
        self.replayGainAlbumGain = song.replayGain?.albumGain
        self.replayGainAlbumPeak = song.replayGain?.albumPeak
        self.replayGainBaseGain = song.replayGain?.baseGain
        self.replayGainFallbackGain = song.replayGain?.fallbackGain
        self.isrc = song.isrc?.first
        self.displayComposer = song.displayComposer
        self.workName = song.works?.first?.name
        self.movementLabel = song.movements?.first?.displayLabel
    }

    @MainActor
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
        self.replayGainTrackGain = track.replayGainTrackGain
        self.replayGainTrackPeak = track.replayGainTrackPeak
        self.replayGainAlbumGain = track.replayGainAlbumGain
        self.replayGainAlbumPeak = track.replayGainAlbumPeak
        self.replayGainBaseGain = track.replayGainBaseGain
        self.replayGainFallbackGain = track.replayGainFallbackGain
        self.isrc = track.isrc
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
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            channelCount: channelCount,
            works: workName.map { [Work(name: $0)] },
            movements: movementLabel.map { [Movement(name: $0)] }
        )
    }
}
