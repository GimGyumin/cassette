// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import AppIntents

/// Flat list cell for an album — cover 60pt, name, artist, year.
/// Used in search results and any flat album list (not grids; see ArtistDetailView).
struct AlbumRow: View {
    @Environment(\.appContainer) private var container
    let albumId: String
    let name: String
    let artist: String?
    let year: Int?
    let coverArtId: String?
    var zoomSourceId: String? = nil
    var zoomNamespace: Namespace.ID? = nil

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtCard(id: coverArtId ?? albumId, size: 56)
                .cassetteMatchedTransitionSource(id: zoomSourceId ?? albumId, in: zoomNamespace)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.cassetteCellTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist {
                    Text(artist)
                        .font(.cassetteCellSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let year {
                    Text(String(year))
                        .font(.cassetteCaption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, CassetteSpacing.xs)
        .contentShape(Rectangle())
        .albumLongPressMenu(
            id: albumId,
            name: name,
            artist: artist,
            coverArtId: coverArtId
        )
        .appEntityIdentifier(entityIdentifier)
    }

    private var entityIdentifier: EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *) else { return nil }
        return OnscreenEntityAnnotation.albumIdentifier(
            id: albumId,
            title: name,
            artist: artist,
            serverId: container?.serverState.activeServer?.id
        )
    }
}

extension AlbumRow {
    init(album: AlbumID3) {
        self.init(
            albumId: album.id,
            name: album.name,
            artist: album.artist,
            year: album.year,
            coverArtId: album.coverArt
        )
    }
}
