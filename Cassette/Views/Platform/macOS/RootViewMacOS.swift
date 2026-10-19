// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftData
import SwiftSonic

struct RootViewMacOS: View {
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \PinnedItem.sortOrder) private var pinnedItems: [PinnedItem]
    // Local mutable copy for native sidebar drag-to-reorder; synced from @Query on count changes.
    @State private var localPinnedItems: [PinnedItem] = []
    @State private var selection: SidebarDestination? = .section(.home)
    @State private var isShowingFullPlayer = false
    @State private var showLyricsSidePanel = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var navigationPath = NavigationPath()

    var body: some View {
        applyNotifications(to: mainChrome)
    }

    private var mainChrome: some View {
        ZStack(alignment: .trailing) {
            MainWindowConfigurator(isFullPlayerVisible: isShowingFullPlayer)
                .frame(width: 0, height: 0)

            // Split view keeps a stable size. Lyrics is a ZStack sibling (not nested in
            // NavigationSplitView / its overlays) so AppKit won't enter a constraint loop.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
            } detail: {
                detailContent
                    .padding(.trailing, showLyricsSidePanel ? 360 : 0)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 120)
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showLyricsSidePanel {
                HStack(spacing: 0) {
                    Divider()
                    MacLyricsSidePanel()
                        .safeAreaInset(edge: .bottom) {
                            Color.clear.frame(height: 120)
                        }
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // Isolate from parent layout negotiation.
                .compositingGroup()
            }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.6), location: 0.5),
                    .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                BottomPlayerBar(
                    onArtworkTap: {
                        showLyricsSidePanel = false
                        animateFullPlayer { isShowingFullPlayer = true }
                    },
                    isLyricsPanelOpen: showLyricsSidePanel,
                    isFullPlayerPresented: isShowingFullPlayer,
                    onLyricsTap: {
                        // Instant toggle — animated insert fights AppKit Auto Layout.
                        showLyricsSidePanel.toggle()
                    }
                )
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)

                if showLyricsSidePanel {
                    Color.clear.frame(width: 360)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if isShowingFullPlayer {
                // Desktop two-column player (CassetteLab chrome) — not the shared iOS FullPlayerView.
                FullPlayerExpandedView(isPresented: $isShowingFullPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(10)
                    .toolbar(.hidden, for: .windowToolbar)
            }
        }
        .frame(minWidth: 1100, minHeight: 500)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: selection) { _, newSelection in
            if isShowingFullPlayer { animateFullPlayer { isShowingFullPlayer = false } }
            // Fresh Search tab root — avoid stacking previous browse destinations under Search.
            if case .section(.search) = newSelection {
                navigationPath = NavigationPath()
            }
        }
    }

    private func applyNotifications<Content: View>(to content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cassetteTogglePlayPause)) { _ in
                Task { await handleTogglePlayPause() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteSkipNext)) { _ in
                Task { try? await container?.playerService.skipToNext() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteSkipPrevious)) { _ in
                Task { try? await container?.playerService.skipToPrevious() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteToggleShuffle)) { _ in
                Task { await container?.playerService.toggleShuffle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteToggleRepeat)) { _ in
                Task {
                    guard let container else { return }
                    await container.playerService.setRepeatMode(container.playerState.repeatMode.next)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteOpenFullPlayer)) { _ in
                showLyricsSidePanel = false
                animateFullPlayer { isShowingFullPlayer = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteOpenFullPlayerLyrics)) { _ in
                // Prefer docked lyrics beside content; FullPlayerExpandedView selects its panel when expanded.
                guard !isShowingFullPlayer else { return }
                showLyricsSidePanel = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteSelectAlbums)) { _ in
                selection = .section(.albums)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteFocusSearch)) { _ in
                selection = .section(.search)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToAlbum)) { note in
                guard let id   = note.userInfo?["albumId"]   as? String,
                      let name = note.userInfo?["albumName"]  as? String else { return }
                let coverArtId = note.userInfo?["coverArtId"] as? String
                animateFullPlayer { isShowingFullPlayer = false }
                selection = .section(.home)
                navigationPath.append(HomeDestination.albumById(id: id, name: name, subtitle: "", coverArtId: coverArtId))
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToArtist)) { note in
                guard let id   = note.userInfo?["artistId"]   as? String,
                      let name = note.userInfo?["artistName"]  as? String else { return }
                let coverArtId = note.userInfo?["coverArtId"] as? String
                animateFullPlayer { isShowingFullPlayer = false }
                selection = .section(.home)
                navigationPath.append(HomeDestination.artistById(id: id, name: name, coverArtId: coverArtId))
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToPlaylist)) { note in
                guard let id   = note.userInfo?["playlistId"] as? String,
                      let name = note.userInfo?["name"]       as? String else { return }
                let coverArtId = note.userInfo?["coverArtId"] as? String
                animateFullPlayer { isShowingFullPlayer = false }
                selection = .section(.library)
                navigationPath.append(HomeDestination.playlistById(id: id, name: name, coverArtId: coverArtId))
            }
    }

    private func animateFullPlayer(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation {
                changes()
            }
        }
    }

    // MARK: - Playback

    private func handleTogglePlayPause() async {
        guard let container else { return }
        if container.playerState.playbackState == .playing {
            await container.playerService.pause()
        } else {
            await container.playerService.resume()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.search)
                sidebarRow(.home)
                sidebarRow(.discover)
                sidebarRow(.library)
            }

            Section("Library") {
                sidebarRow(.recentlyAdded)
                sidebarRow(.albums)
                sidebarRow(.artists)
                sidebarRow(.playlists)
                sidebarRow(.favorites)
                sidebarRow(.downloads)
            }

            if !localPinnedItems.isEmpty {
                Section("Pinned") {
                    ForEach(localPinnedItems) { item in
                        pinnedRow(item)
                            .tag(SidebarDestination.pinned(item.id))
                    }
                    .onMove { source, destination in
                        localPinnedItems.move(fromOffsets: source, toOffset: destination)
                        container?.pinService.reorder(items: localPinnedItems)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            userFooter
        }
        .onAppear { localPinnedItems = pinnedItems }
        .onChange(of: pinnedItems.count) { _, _ in localPinnedItems = pinnedItems }
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        Label(section.displayLabel, systemImage: section.systemImage)
            .tag(SidebarDestination.section(section))
    }

    @ViewBuilder
    private func pinnedRow(_ item: PinnedItem) -> some View {
        Label {
            Text(item.displayName)
        } icon: {
            if let coverArtId = item.coverArtId {
                CoverArtView(
                    id: coverArtId,
                    size: 22,
                    cornerRadius: PinnedItemType(rawValue: item.itemType) == .artist ? 11 : 3,
                    placeholderSystemImage: pinnedSidebarIcon(for: item.itemType)
                )
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: pinnedSidebarIcon(for: item.itemType))
            }
        }
        .contextMenu {
            Button {
                selection = .pinned(item.id)
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }

            Divider()

            Button(role: .destructive) {
                if let type = PinnedItemType(rawValue: item.itemType) {
                    container?.pinService.unpin(itemType: type, itemId: item.itemId)
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        }
    }

    private func pinnedSidebarIcon(for itemType: String) -> String {
        switch PinnedItemType(rawValue: itemType) {
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .song: "music.note"
        case .artist: "person.fill"
        case .none: "pin"
        }
    }

    @ViewBuilder
    private var userFooter: some View {
        if let server = container?.serverState.activeServer {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.displayName)
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(server.username)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        NavigationStack(path: $navigationPath) {
            detailView(for: selection ?? .section(.home))
                .environment(\.registersHomeDestinations, false)
                .navigationDestination(for: HomeDestination.self) { destination in
                    macOSDestinationView(destination)
                }
        }
    }

    /// CassetteLab desktop detail chrome — hero + list, not the shared iOS immersive detail views.
    @ViewBuilder
    private func macOSDestinationView(_ destination: HomeDestination) -> some View {
        switch destination {
        case .albumCollection(let collection):
            AlbumShelfCollectionView(collection: collection)
        case .libraryAlbums:
            AlbumsListView()
        case .libraryArtists:
            ArtistsListMacOS()
        case .librarySongs:
            SongsListView()
        case .libraryPlaylists:
            PlaylistListView()
        case .libraryFavorites:
            FavoritesView()
        case .libraryDownloads:
            DownloadedView()
        case .albumPush(let id, let name, let coverArtId, _):
            AlbumDetailMacOS(albumId: id, albumName: name, coverArtId: coverArtId)
        case .album(let album):
            AlbumDetailMacOS(albumId: album.id, albumName: album.name, coverArtId: album.coverArt)
        case .artist(let artist):
            ArtistDetailMacOS(artistId: artist.id, artistName: artist.name, coverArtId: artist.coverArt)
        case .albumById(let id, let name, _, let coverArtId):
            AlbumDetailMacOS(albumId: id, albumName: name, coverArtId: coverArtId)
        case .artistById(let id, let name, let coverArtId):
            ArtistDetailMacOS(artistId: id, artistName: name, coverArtId: coverArtId)
        case .artistPush(let id, let name, let coverArtId, _):
            ArtistDetailMacOS(artistId: id, artistName: name, coverArtId: coverArtId)
        case .playlist(let playlist):
            PlaylistDetailMacOS(playlistId: playlist.id, name: playlist.name, coverArtId: playlist.coverArt)
        case .playlistById(let id, let name, let coverArtId):
            PlaylistDetailMacOS(playlistId: id, name: name, coverArtId: coverArtId)
        case .downloadedAlbum(let display):
            AlbumDetailMacOS(
                albumId: display.albumId,
                albumName: display.name,
                coverArtId: display.coverArtId
            )
        case .replay:
            WrappedView()
        case .replayPeriod(let period):
            WrappedView(initialPeriod: period)
        case .offlineArtist(let artist):
            OfflineArtistAlbumsView(artist: artist)
        case .offlineAlbum(let album):
            AlbumDetailMacOS(
                albumId: album.albumId,
                albumName: album.albumName,
                coverArtId: album.coverArtId
            )
        case .personalMix(let kind):
            PlaylistDetailView(generatedSource: .personalMix(kind))
        }
    }

    @ViewBuilder
    private func detailView(for destination: SidebarDestination) -> some View {
        switch destination {
        case .section(let section):
            sectionView(for: section)
        case .pinned(let id):
            pinnedDetail(for: id)
                .id(id)
        }
    }

    @ViewBuilder
    private func sectionView(for section: SidebarSection) -> some View {
        switch section {
        case .search:    SearchView(path: $navigationPath)
        case .home:      DashboardHomeView()
        case .discover:  DiscoverView()
        case .library:   HomeView()
        case .recentlyAdded: RecentlyAddedAlbumsView()
        case .albums:    AlbumsListView()
        case .artists:   ArtistsListMacOS()
        case .playlists: PlaylistListView()
        case .favorites: FavoritesView()
        case .downloads: DownloadedView()
        }
    }

    @ViewBuilder
    private func pinnedDetail(for id: String) -> some View {
        if let item = pinnedItems.first(where: { $0.id == id }) {
            switch PinnedItemType(rawValue: item.itemType) {
            case .album:
                AlbumDetailMacOS(
                    albumId: item.itemId,
                    albumName: item.displayName,
                    coverArtId: item.coverArtId,
                    showBackButton: false
                )
            case .playlist:
                PlaylistDetailMacOS(
                    playlistId: item.itemId,
                    name: item.displayName,
                    coverArtId: item.coverArtId,
                    showBackButton: false
                )
            case .artist:
                ArtistDetailMacOS(
                    artistId: item.itemId,
                    artistName: item.displayName,
                    coverArtId: item.coverArtId,
                    showBackButton: false
                )
            case .song:
                // Songs pin to Home as playable tiles; opening from the sidebar starts playback.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        let song = DisplayableSong(
                            id: item.itemId,
                            title: item.displayName,
                            artist: item.displaySubtitle.isEmpty ? nil : item.displaySubtitle,
                            coverArtId: item.coverArtId
                        )
                        Task {
                            try? await container?.playerService.play(tracks: [song], startIndex: 0)
                        }
                    }
            case .none:
                ContentUnavailableView("Unknown item type", systemImage: "questionmark")
            }
        } else {
            ContentUnavailableView("Item not found", systemImage: "pin.slash")
        }
    }
}

// MARK: - Window configurator

private struct MainWindowConfigurator: NSViewRepresentable {
    let isFullPlayerVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName("CassetteMainWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            // titlebarAppearsTransparent must be true unconditionally: on macOS 26 (Liquid Glass)
            // the titlebar material bleeds a frosted-glass overlay into scrolled content when
            // this is false, and no SwiftUI modifier can suppress it. The full-player overlay
            // sets it to true anyway, so keeping it true at all times is consistent.
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = isFullPlayerVisible
        }
    }
}
#endif
