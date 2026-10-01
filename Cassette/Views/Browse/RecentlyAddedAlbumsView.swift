// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog

/// Sidebar “Recently Added” destination — newest library albums (not the full A–Z catalog).
struct RecentlyAddedAlbumsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var albums: [AlbumID3] = []
    @State private var isLoading = false
    @State private var error: UserFacingError?

    private var usesGrid: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if isLoading && albums.isEmpty {
                LoadingStateView()
            } else if let error, albums.isEmpty {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Unable to Load", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    subtitle: error.displayMessage,
                    action: .init(label: String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        Task { await load() }
                    }
                )
            } else if albums.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: String(localized: "No Recent Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    subtitle: String(localized: "Newly added albums will appear here.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                )
            } else if usesGrid {
                albumGrid
            } else {
                albumList
            }
        }
        .navigationTitle(String(localized: "Recently Added", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .task { await load() }
        .refreshable { await load() }
    }

    private var albumGrid: some View {
        GeometryReader { geo in
            let count = gridColumnCount(for: geo.size.width)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(albums) { album in
                        NavigationLink(value: HomeDestination.album(album)) {
                            AlbumGridCell(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .miniPlayerBottomMargin()
        }
    }

    private var albumList: some View {
        List(albums) { album in
            NavigationLink(value: HomeDestination.album(album)) {
                AlbumRow(
                    albumId: album.id,
                    name: album.name,
                    artist: album.artist,
                    year: album.year,
                    coverArtId: album.coverArt
                )
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomMargin()
    }

    private func load() async {
        guard let library = container?.libraryService else { return }
        isLoading = true
        error = nil
        do {
            albums = try await library.recentlyAddedAlbums(size: 100)
        } catch {
            if !UserFacingError.isCancellation(error) {
                self.error = UserFacingError.from(error)
                Logger.library.error("RecentlyAddedAlbumsView load failed: \(error, privacy: .public)")
            }
        }
        isLoading = false
    }

    private func gridColumnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<700: return 3
        case ..<900: return 4
        case ..<1200: return 5
        case ..<1600: return 6
        default: return 7
        }
    }
}
