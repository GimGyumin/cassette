// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Album shelf: always a single horizontal scrolling row (iPhone, iPad, macOS).
struct AdaptiveAlbumShelf: View {
    let title: String
    let albums: [AlbumID3]
    var showArtist: Bool = true
    var destination: (AlbumID3) -> HomeDestination = { .album($0) }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var itemSize: CGFloat {
        #if os(macOS)
        160
        #else
        horizontalSizeClass == .regular ? 168 : 150
        #endif
    }

    /// Cover + title (+ optional artist) — keep ScrollView height stable across size-class changes.
    private var rowHeight: CGFloat {
        itemSize + CassetteSpacing.xs + 44
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(title)
                .font(.cassetteSectionTitle)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CassetteSpacing.m) {
                    ForEach(albums) { album in
                        NavigationLink(value: destination(album)) {
                            albumCard(album)
                        }
                        .buttonStyle(.plain)
                        .albumLongPressMenu(album)
                    }
                }
                .frame(height: rowHeight)
                .padding(.vertical, 1)
            }
            .frame(height: rowHeight + 2)
            // Keep the row from scrolling under the iPad sidebarAdaptable chrome.
            .clipped()
        }
    }

    private func albumCard(_ album: AlbumID3) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            CoverArtView(id: album.coverArt ?? album.id, size: Int(itemSize + 30))
                .frame(width: itemSize, height: itemSize)
                .cassetteCoverStyle(cornerRadius: CassetteCornerRadius.large)
            Text(album.name)
                .foregroundStyle(.primary)
                .font(.cassetteCellTitle)
                .lineLimit(1)
            if showArtist, let artist = album.artist {
                Text(artist)
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: itemSize, alignment: .leading)
    }
}
