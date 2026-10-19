// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Sendable bridge from PlayerService to NowPlayingService.
/// Carries all metadata needed to update MPNowPlayingInfoCenter and load artwork.
nonisolated struct NowPlayingSnapshot: Sendable {
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let position: TimeInterval
    let playbackRate: Float
    let artworkURL: URL?
    let artworkHeaders: [String: String]
    /// coverArtId from the source song — used by NowPlayingService to check
    /// ArtworkImageCache before falling back to a URL fetch.
    let coverArtId: String?
    /// Album id, so the lock screen can prefer the cover a downloaded album stored on disk
    /// (recorded during library preparation) over the song's own media-file cover id.
    let albumId: String?
    /// True when the current playback is a live stream (radio). When true, duration and
    /// position are not meaningful — NowPlayingService omits them from the info dict so
    /// Control Center hides the scrubber automatically.
    let isLiveStream: Bool
    /// The radio station's display name when isLiveStream is true; nil otherwise.
    let radioStationName: String?
    /// ISRC for system Music Haptics (Settings → Accessibility → Music Haptics).
    let isrc: String?
    /// Stable server identifier for distinguishing tracks with otherwise identical metadata.
    let trackId: String?
    /// Zero-based position and total count exposed to the system Now Playing queue.
    let queueIndex: Int?
    let queueCount: Int?
    let publication: PlaybackPublication?
    let timestamp: Date

    /// Some OpenSubsonic recommendation endpoints omit `coverArt` even though the song ID
    /// is accepted by the cover-art endpoint. Keep that fallback consistent with the player UI.
    var effectiveCoverArtId: String? {
        let explicit = coverArtId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty { return explicit }
        let fallback = trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }

    init(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval,
        position: TimeInterval,
        playbackRate: Float,
        artworkURL: URL?,
        artworkHeaders: [String: String],
        coverArtId: String?,
        albumId: String? = nil,
        isLiveStream: Bool,
        radioStationName: String?,
        isrc: String?,
        trackId: String? = nil,
        queueIndex: Int? = nil,
        queueCount: Int? = nil,
        publication: PlaybackPublication? = nil,
        timestamp: Date = Date()
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.playbackRate = playbackRate
        self.artworkURL = artworkURL
        self.artworkHeaders = artworkHeaders
        self.coverArtId = coverArtId
        self.albumId = albumId
        self.isLiveStream = isLiveStream
        self.radioStationName = radioStationName
        self.isrc = isrc
        self.trackId = trackId
        self.queueIndex = queueIndex
        self.queueCount = queueCount
        self.publication = publication
        self.timestamp = timestamp
    }
}

extension NowPlayingSnapshot {
    nonisolated func updatingPlayback(position: Double, rate: Float, duration: Double,
                          publication: PlaybackPublication? = nil, timestamp: Date = Date()) -> Self {
        Self(title: title, artist: artist, album: album, duration: duration, position: position,
             playbackRate: rate, artworkURL: artworkURL, artworkHeaders: artworkHeaders,
             coverArtId: coverArtId, albumId: albumId, isLiveStream: isLiveStream,
             radioStationName: radioStationName, isrc: isrc, trackId: trackId,
             queueIndex: queueIndex, queueCount: queueCount, publication: publication ?? self.publication,
             timestamp: timestamp)
    }

    nonisolated func preservingArtwork(from previous: Self?) -> Self {
        Self(title: title, artist: artist, album: album, duration: duration, position: position,
             playbackRate: playbackRate, artworkURL: artworkURL ?? previous?.artworkURL,
             artworkHeaders: artworkURL == nil ? (previous?.artworkHeaders ?? artworkHeaders) : artworkHeaders,
             coverArtId: coverArtId, albumId: albumId, isLiveStream: isLiveStream,
             radioStationName: radioStationName, isrc: isrc, trackId: trackId,
             queueIndex: queueIndex, queueCount: queueCount, publication: publication, timestamp: timestamp)
    }

    nonisolated func projectingPlayback(to date: Date = Date()) -> Self {
        let elapsed = position + max(0, date.timeIntervalSince(timestamp)) * Double(max(0, playbackRate))
        return updatingPlayback(position: min(max(0, elapsed), max(0, duration)), rate: playbackRate,
                                duration: duration, timestamp: date)
    }
}
