// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Adaptive grid cell for album browse surfaces.
/// Displays a square cover art, album name, and artist name.
struct AlbumGridCell: View {
    let album: AlbumID3
    var zoomSourceId: String? = nil
    var zoomNamespace: Namespace.ID? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                CoverArtView(id: album.coverArt ?? album.id, size: Int(width * 2))
                    .frame(width: width, height: width)
                    .cassetteCoverStyle(cornerRadius: CassetteCornerRadius.standard)
            }
            .aspectRatio(1, contentMode: .fit)
            .cassetteMatchedTransitionSource(id: zoomSourceId, in: zoomNamespace)
            #if os(macOS)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
            #endif

            Text(album.name)
                .foregroundStyle(.primary)
                .font(.cassetteCellTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let artist = album.artist {
                Text(artist)
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .albumLongPressMenu(album)
    }
}
