// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

@Model
final class DownloadedTrack {
    var id: UUID
    /// Cassette-owned identity. Existing rows lazily adopt `id.uuidString`; keeping this
    /// optional makes the schema addition a non-destructive lightweight migration.
    var localStableID: String?
    var songId: String
    /// Current server representation, while `songId` remains the historical key used by the
    /// on-disk filename and old queues. Never overwrite `songId` during ID reconciliation.
    var currentRemoteID: String?
    var legacyRemoteIDs: [String]?
    var jellyfinID: String?
    var serverId: UUID
    var albumId: String?
    var filePath: String        // relative to Documents/app.cassette/downloads/
    var fileSize: Int64
    var mimeType: String
    var downloadedAt: Date
    // Denormalized metadata for offline display (no network required in offline mode)
    var title: String
    var artist: String?
    var artistId: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var durationSeconds: Int?
    var mediaPath: String?
    var musicBrainzID: String?
    var isrc: String?
    var coverArtId: String?
    var suffix: String?
    var genre: String?
    /// Audio metadata for offline engine routing (Atmos / multichannel → AVPlayer).
    var bitRate: Int?
    var bitDepth: Int?
    var samplingRate: Int?
    var channelCount: Int?
    var comment: String?
    /// Optional so existing stores migrate without rewriting downloaded rows.
    var explicitStatus: String?
    // ReplayGain metadata — captured at download time for offline normalization.
    var replayGainTrackGain: Double?
    var replayGainTrackPeak: Double?
    var replayGainAlbumGain: Double?
    var replayGainAlbumPeak: Double?
    var replayGainBaseGain: Double?
    var replayGainFallbackGain: Double?

    init(
        id: UUID = UUID(),
        localStableID: String? = nil,
        songId: String,
        currentRemoteID: String? = nil,
        legacyRemoteIDs: [String]? = nil,
        jellyfinID: String? = nil,
        serverId: UUID,
        albumId: String? = nil,
        filePath: String,
        fileSize: Int64,
        mimeType: String,
        downloadedAt: Date = Date(),
        title: String,
        artist: String? = nil,
        artistId: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        durationSeconds: Int? = nil,
        mediaPath: String? = nil,
        musicBrainzID: String? = nil,
        isrc: String? = nil,
        coverArtId: String? = nil,
        suffix: String? = nil,
        genre: String? = nil,
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
        replayGainFallbackGain: Double? = nil
    ) {
        self.id = id
        self.localStableID = localStableID ?? id.uuidString
        self.songId = songId
        self.currentRemoteID = currentRemoteID ?? songId
        self.legacyRemoteIDs = legacyRemoteIDs
        self.jellyfinID = jellyfinID
        self.serverId = serverId
        self.albumId = albumId
        self.filePath = filePath
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.downloadedAt = downloadedAt
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationSeconds = durationSeconds
        self.mediaPath = mediaPath
        self.musicBrainzID = musicBrainzID
        self.isrc = isrc
        self.coverArtId = coverArtId
        self.suffix = suffix
        self.genre = genre
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
    }
}
