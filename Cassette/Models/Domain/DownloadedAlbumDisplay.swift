// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

/// Display projection unifying full `DownloadedAlbum` records with partial albums
/// inferred from `DownloadedTrack` rows. Used for offline album lists and Settings.
nonisolated struct DownloadedAlbumDisplay: Identifiable, Sendable, Hashable {
    let id: String              // Server-scoped UI identity; albumId remains the API identifier.
    let albumId: String
    let serverId: UUID
    let name: String
    let artist: String?
    let coverArtId: String?
    /// Number of tracks currently downloaded (always equal to the count of `DownloadedTrack` rows for this albumId).
    let downloadedTracksCount: Int
    /// Total tracks expected. `nil` for partial albums (no `DownloadedAlbum` record).
    let totalTracksCount: Int?
    /// `true` if a `DownloadedAlbum` record exists (the user explicitly downloaded the full album).
    let hasFullDownloadIntent: Bool
}

enum DownloadedAlbumMerger {
    private struct AlbumKey: Hashable {
        let serverId: UUID
        let albumId: String
        var displayID: String { "\(serverId.uuidString):\(albumId)" }
    }

    /// Build a unified, deduplicated list of displayable albums from records + tracks.
    /// `records` provides full-intent albums with their `totalTracksCount`.
    /// `tracks` provides partial albums for any `albumId` not already in `records`.
    /// Returns sorted by album name (case-insensitive).
    static func merge(
        records: [DownloadedAlbum],
        tracks: [DownloadedTrack]
    ) -> [DownloadedAlbumDisplay] {
        var byAlbumId: [AlbumKey: DownloadedAlbumDisplay] = [:]
        // Group once, rather than filtering the entire track library for every album.
        let groupedTracks: [AlbumKey: [DownloadedTrack]] = tracks.reduce(into: [:]) { groups, track in
            guard let albumId = track.albumId else { return }
            groups[AlbumKey(serverId: track.serverId, albumId: albumId), default: []].append(track)
        }

        // Full-intent albums first.
        for record in records {
            let key = AlbumKey(serverId: record.serverId, albumId: record.albumId)
            let trackCount = groupedTracks[key]?.count ?? 0
            byAlbumId[key] = DownloadedAlbumDisplay(
                id: key.displayID,
                albumId: record.albumId,
                serverId: record.serverId,
                name: record.name,
                artist: record.artist,
                coverArtId: record.coverArtId,
                downloadedTracksCount: trackCount,
                totalTracksCount: record.totalTracksCount,
                hasFullDownloadIntent: true
            )
        }

        // Partial albums: groups of tracks whose albumId has no matching record.
        for (key, group) in groupedTracks where byAlbumId[key] == nil {
            guard let first = group.first else { continue }
            byAlbumId[key] = DownloadedAlbumDisplay(
                id: key.displayID,
                albumId: key.albumId,
                serverId: first.serverId,
                name: first.album ?? "Unknown Album",
                artist: first.artist,
                coverArtId: first.coverArtId,
                downloadedTracksCount: group.count,
                totalTracksCount: nil,
                hasFullDownloadIntent: false
            )
        }

        return byAlbumId.values.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
