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
    var prominent = false
    var showsSeeAll = false
    var destination: (AlbumID3) -> HomeDestination = { .album($0) }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var prominentTextHeight: CGFloat = 56

    private var itemSize: CGFloat {
        #if os(macOS)
        160
        #else
        horizontalSizeClass == .regular ? 180 : (prominent ? 160 : 150)
        #endif
    }

    /// Cover + title (+ optional artist) — keep ScrollView height stable across size-class changes.
    private var rowHeight: CGFloat {
        itemSize + CassetteSpacing.xs + (prominent ? prominentTextHeight : 44)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            if showsSeeAll {
                NavigationLink(value: HomeDestination.albumCollection(AlbumShelfCollection(
                    title: title, items: albums.map { .init(album: $0, destination: destination($0)) }
                ))) {
                    HomeShelfHeading(title: title, showsChevron: true)
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(prominent ? .title2.bold() : .cassetteSectionTitle)
            }

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
                .font(prominent ? .body.weight(.semibold) : .cassetteCellTitle)
                .lineLimit(1)
            if showArtist, let artist = album.artist {
                Text(artist)
                    .font(prominent ? .subheadline : .cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: itemSize, alignment: .leading)
    }
}

struct AlbumShelfCollectionView: View {
    let collection: AlbumShelfCollection
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 20) {
                ForEach(collection.items) { item in
                    let album = item.album
                    NavigationLink(value: item.destination) {
                        VStack(alignment: .leading, spacing: 8) {
                            CoverArtView(id: album.coverArt ?? album.id, size: 360)
                                .aspectRatio(1, contentMode: .fit).cassetteCoverStyle(cornerRadius: 12)
                            Text(album.name).font(.body.weight(.semibold)).lineLimit(1)
                            if let artist = album.artist { Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain).albumLongPressMenu(album)
                }
            }.padding(16)
        }
        .navigationTitle(collection.title)
        .miniPlayerBottomMargin()
        .cassetteContentWidth(.fill)
    }
}
