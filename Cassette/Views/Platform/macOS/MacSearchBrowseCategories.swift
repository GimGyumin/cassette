// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI

/// Apple Music–style browse tiles shown under Search when the query is empty.
struct MacSearchBrowseCategories: View {
    @Binding var path: NavigationPath

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private let tiles: [(title: String, systemImage: String, color: Color, destination: HomeDestination)] = [
        ("Albums", "square.stack.fill", .pink, .libraryAlbums),
        ("Artists", "music.mic", .purple, .libraryArtists),
        ("Playlists", "music.note.list", .blue, .libraryPlaylists),
        ("Favorites", "star.fill", .orange, .libraryFavorites),
        ("Downloads", "arrow.down.circle.fill", .teal, .libraryDownloads),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.m) {
            Text(String(localized: "Browse", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteSectionTitle)
                .padding(.horizontal, CassetteSpacing.l)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tiles, id: \.title) { tile in
                    Button {
                        path.append(tile.destination)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [tile.color, tile.color.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: tile.systemImage)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.28))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                .padding(12)
                            Text(tile.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                        .frame(height: 88)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, CassetteSpacing.l)
        }
        .padding(.bottom, CassetteSpacing.xl)
    }
}
#endif
