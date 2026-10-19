// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if os(iOS)
import UIKit
#endif

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ChromeAppearance.self) private var chromeAppearance
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var searchPath = NavigationPath()
    #if os(macOS)
    @State private var searchText = ""
    #endif
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var discoverPath = NavigationPath()
    @State private var recentlyAddedPath = NavigationPath()
    @State private var artistsPath = NavigationPath()
    @State private var albumsPath = NavigationPath()
    @State private var favoritesPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var selectedTab: AppTab = .home
    @State private var mountedTabs: Set<AppTab> = [.home]
    @State private var showingFullPlayer = false
    @State private var openPlayerWithLyrics = false
    @State private var openPlayerWithQueue = false
    @State private var showAccountSheet = false
    @State private var showCreatePlaylist = false
    /// Path change requested from the full player / a notification, applied after the player's cover is
    /// completely gone. `mode` decides whether the tab's existing stack is preserved.
    @State private var pendingNavigation: (destination: HomeDestination, tab: AppTab, mode: NavigationMode)?
    @Namespace private var playerZoom
    private let fullPlayerZoomID = "full-player"
    /// Identity of this `tabs` hierarchy, so a device log can tell a re-render from a rebuild.
    @State private var tabsInstanceID = UUID()

    #if os(iOS)
    private var showsSidebarLibrarySections: Bool {
        horizontalSizeClass == .regular
    }
    #endif

    private enum AppTab: Hashable {
        case home, discover, library, search
        case recentlyAdded, artists, albums, favorites, playlists, downloads
    }

    /// Whether a deferred navigation replaces the tab's stack or pushes onto it.
    private enum NavigationMode {
        /// Show the destination as the only entry (deep-link semantics).
        case replace
        /// Push the destination on top of what the user was looking at, so Back returns there.
        case append
    }

    /// Follows the frontmost themed detail page (album/playlist/artist) so the tab bar and
    /// mini player glyphs flip white/black to match its cover-derived background.
    private var resolvedColorScheme: ColorScheme {
        chromeAppearance.overrideColorScheme ?? colorScheme
    }

    /// Intercepts tab selection so re-tapping Search focuses the field.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .search, selectedTab == .search {
                    NotificationCenter.default.post(name: .cassetteFocusSearch, object: nil)
                }
                mountedTabs.insert(newValue)
                selectedTab = newValue
            }
        )
    }

    private var accountDisplayName: String {
        container?.serverState.activeServer?.username
            ?? String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    // MARK: - Tabs View
    @ViewBuilder
    private var tabs: some View {
        TabView(selection: tabSelection) {
            // Search first so the sidebar lists it at the top (Apple Music).
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    #if os(macOS)
                    SearchView(searchQuery: $searchText, path: $searchPath)
                        .environment(\.registersHomeDestinations, true)
                    #else
                    SearchView(path: $searchPath)
                        .environment(\.registersHomeDestinations, true)
                    #endif
                }
                .environment(\.detailNavigationPath, $searchPath)
                .onChange(of: searchPath.count) { old, new in logPathChange(.search, from: old, to: new) }
            }

            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $homePath) {
                    reachabilityGated { DashboardHomeView() }
                        // Destination registration must survive cellular/reachability changes.
                        .navigationDestination(for: HomeDestination.self) { destination in
                            homeDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $homePath)
                .onChange(of: homePath.count) { old, new in logPathChange(.home, from: old, to: new) }
            }

            Tab("Discover", systemImage: "square.grid.2x2.fill", value: AppTab.discover) {
                NavigationStack(path: $discoverPath) {
                    reachabilityGated { DiscoverView() }
                        // Destination registration must survive cellular/reachability changes.
                        .navigationDestination(for: HomeDestination.self) { destination in
                            homeDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $discoverPath)
                .onChange(of: discoverPath.count) { old, new in logPathChange(.discover, from: old, to: new) }
            }

            // Library hub — keep it available in every tab presentation, including the
            // iPad floating tab bar and sidebar.
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $libraryPath) {
                    HomeView()
                        .environment(\.registersHomeDestinations, false)
                        .navigationDestination(for: HomeDestination.self) { destination in
                            libraryDestinationView(destination)
                        }
                }
                .environment(\.detailNavigationPath, $libraryPath)
                .onChange(of: libraryPath.count) { old, new in logPathChange(.library, from: old, to: new) }
            }
            #if os(iOS)
            if showsSidebarLibrarySections {
                TabSection(String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Tab("Recently Added", systemImage: "clock", value: AppTab.recentlyAdded) {
                        NavigationStack(path: $recentlyAddedPath) {
                            lazySidebarRoot(when: .recentlyAdded) { RecentlyAddedAlbumsView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $recentlyAddedPath)
                        .onChange(of: recentlyAddedPath.count) { old, new in logPathChange(.recentlyAdded, from: old, to: new) }
                    }
                    Tab("Artists", systemImage: "music.mic", value: AppTab.artists) {
                        NavigationStack(path: $artistsPath) {
                            lazySidebarRoot(when: .artists) { ArtistListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $artistsPath)
                        .onChange(of: artistsPath.count) { old, new in logPathChange(.artists, from: old, to: new) }
                    }
                    Tab("Albums", systemImage: "square.stack", value: AppTab.albums) {
                        NavigationStack(path: $albumsPath) {
                            lazySidebarRoot(when: .albums) { AlbumsListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $albumsPath)
                        .onChange(of: albumsPath.count) { old, new in logPathChange(.albums, from: old, to: new) }
                    }
                    Tab("Favorites", systemImage: "star", value: AppTab.favorites) {
                        NavigationStack(path: $favoritesPath) {
                            lazySidebarRoot(when: .favorites) { FavoritesView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $favoritesPath)
                        .onChange(of: favoritesPath.count) { old, new in logPathChange(.favorites, from: old, to: new) }
                    }
                    Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                        NavigationStack(path: $downloadsPath) {
                            // Never gated: this is where offline listening lives.
                            lazySidebarRoot(when: .downloads, serverBacked: false) { DownloadedView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $downloadsPath)
                        .onChange(of: downloadsPath.count) { old, new in logPathChange(.downloads, from: old, to: new) }
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)

                TabSection(String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Tab("All Playlists", systemImage: "square.grid.2x2", value: AppTab.playlists) {
                        NavigationStack(path: $playlistsPath) {
                            lazySidebarRoot(when: .playlists) { PlaylistListView() }
                                .navigationDestination(for: HomeDestination.self) { libraryDestinationView($0) }
                        }
                        .environment(\.detailNavigationPath, $playlistsPath)
                        .onChange(of: playlistsPath.count) { old, new in logPathChange(.playlists, from: old, to: new) }
                    }
                }
                .sectionActions {
                    Button(String(localized: "New Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "plus") {
                        showCreatePlaylist = true
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
            #endif
        }
        #if os(iOS)
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            Button {
                showAccountSheet = true
            } label: {
                Label {
                    Text(accountDisplayName)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "person.crop.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
        #endif
    }

    /// Content that cannot be built without the active server: while it is unreachable the tab shows
    /// the offline state rather than an empty shelf or a spinner that never resolves. Library,
    /// Downloads and Search are deliberately excluded — they read local data.
    ///
    /// The offline state is painted *over* the mounted content. Swapping the root for another view
    /// type — what this used to do — rebuilds the tab's `NavigationStack`: a link that flaps while the
    /// user is deep in the stack (a reachability probe timing out behind an open album → artist page)
    /// destroyed and re-created every pushed page, re-ran their `.task`s and left the interactive pop
    /// gesture dead. A device log showed the album page under an open artist page re-running its
    /// album + More-By + description load twice more, with the description fetch failing each time.
    /// The overlay keeps the stack's identity: pages keep their state, tasks do not re-run, and only
    /// what is on screen flips while the server is away. It is opaque and hit-testable, so the tab
    /// still looks and behaves exactly as before.
    @ViewBuilder
    private func reachabilityGated<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .accessibilityHidden(container?.serverState.isServerReachable == false)
            .overlay {
                if container?.serverState.isServerReachable == false {
                    ServerUnreachableView()
                        .background(PlatformColors.systemBackground)
                        .contentShape(Rectangle())
                        .onAppear {
                            Logger.ui.debug("[TABS] unreachable overlay shown — server-backed tabs covered")
                        }
                        .onDisappear {
                            Logger.ui.debug("[TABS] unreachable overlay dismissed")
                        }
                }
            }
    }

    #if os(iOS)
    /// Mount on first selection and preserve the root thereafter, including scroll/task state.
    @ViewBuilder
    private func lazySidebarRoot<Content: View>(
        when tab: AppTab,
        serverBacked: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if selectedTab == tab || mountedTabs.contains(tab) {
            if serverBacked {
                reachabilityGated { content() }
            } else {
                content()
            }
        } else {
            Color.clear
        }
    }
    #endif

    @ViewBuilder
    private func homeDestinationView(_ destination: HomeDestination) -> some View {
        libraryDestinationView(destination)
    }

    @ViewBuilder
    private func libraryDestinationView(_ destination: HomeDestination) -> some View {
        switch destination {
        case .albumCollection(let collection):
            AlbumShelfCollectionView(collection: collection)
        case .libraryAlbums:
            AlbumsListView()
        case .libraryArtists:
            ArtistListView()
        case .librarySongs:
            SongsListView()
        case .libraryPlaylists:
            PlaylistListView()
        case .libraryFavorites:
            FavoritesView()
        case .libraryDownloads:
            DownloadedView()
        case .albumPush(let id, let name, let coverArtId, _):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .album(let album):
            AlbumDetailView(album: album)
        case .artist(let artist):
            ArtistDetailView(artist: artist)
        case .albumById(let id, let name, _, let coverArtId):
            AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
        case .artistById(let id, let name, let coverArtId):
            ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .artistPush(let id, let name, let coverArtId, _):
            ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .playlistById(let id, let name, let coverArtId):
            PlaylistDetailView(playlistId: id, name: name, coverArtId: coverArtId)
        case .downloadedAlbum(let display):
            AlbumDetailView(
                albumId: display.albumId,
                albumName: display.name,
                coverArtId: display.coverArtId,
                mode: .downloadedOnly
            )
        case .replay:
            WrappedView()
        case .replayPeriod(let period):
            WrappedView(initialPeriod: period)
        case .offlineArtist(let artist):
            OfflineArtistAlbumsView(artist: artist)
        case .offlineAlbum(let album):
            AlbumDetailView(
                albumId: album.albumId,
                albumName: album.albumName,
                coverArtId: album.coverArtId
            )
        case .personalMix(let kind):
            PlaylistDetailView(generatedSource: .personalMix(kind))
        }
    }

    private func logPathChange(_ tab: AppTab, from old: Int, to new: Int) {
        Logger.ui.debug("[NAV] path tab=\(String(describing: tab), privacy: .public) \(old, privacy: .public) -> \(new, privacy: .public) tabs=\(tabsInstanceID, privacy: .public)")
    }

    var body: some View {
#if os(iOS)
        Group {
            if #available(iOS 26.1, *) {
                tabs
                    .tabBarMinimizeBehavior(selectedTab == .search ? .never : .onScrollDown)
                    .tabViewBottomAccessory(isEnabled: hasPlayerContent) {
                        miniPlayerAccessory(usesSystemAccessory: true)
                    }
            } else if #available(iOS 26.0, *) {
                tabs
                    .tabBarMinimizeBehavior(selectedTab == .search ? .never : .onScrollDown)
                    .tabViewBottomAccessory {
                        if hasPlayerContent { miniPlayerAccessory(usesSystemAccessory: true) }
                    }
            } else {
                tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasPlayerContent { miniPlayerAccessory(usesSystemAccessory: false) }
                }
            }
        }
        .fullScreenCover(isPresented: $showingFullPlayer, onDismiss: fullPlayerDidDismiss) {
            FullPlayerView(openWithLyrics: openPlayerWithLyrics, openWithQueue: openPlayerWithQueue)
                .presentationBackground(.clear)
                .cassetteZoomTransition(sourceID: fullPlayerZoomID, in: playerZoom)
        }
        .toolbarColorScheme(resolvedColorScheme, for: .tabBar)
        .onChange(of: selectedTab) { _, tab in mountedTabs.insert(tab) }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet { _ in }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToArtist)) { note in
            handleNavigateToArtist(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToAlbum)) { note in
            handleNavigateToAlbum(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteNavigateToPlaylist)) { note in
            handleNavigateToPlaylist(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteSearchInApp)) { _ in
            selectedTab = .search
        }
        .task {
            // Rebuild indicator: one line per `MainTabView` instance. A new id here (without a
            // relaunch) means the whole tab hierarchy — every stack and pushed page — was rebuilt,
            // which is what leaves a pushed page's back gesture dead.
            Logger.ui.debug("[TABS] MainTabView instance=\(tabsInstanceID, privacy: .public) appeared")
            if #available(iOS 27.0, *), UserDefaults.standard.string(forKey: "cassette.siri.pendingSearchQuery") != nil {
                selectedTab = .search
            }
        }
        .background {
            SearchTabReselectObserver {
                NotificationCenter.default.post(name: .cassetteFocusSearch, object: nil)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
#else
        tabs
            .safeAreaInset(edge: .bottom) {
                MiniPlayerAccessoryView(
                    showingFullPlayer: $showingFullPlayer
                )
            }
            .sheet(isPresented: $showingFullPlayer) {
                FullPlayerView()
            }
#endif
    }

#if os(iOS)
    private var hasPlayerContent: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    private func miniPlayerAccessory(usesSystemAccessory: Bool) -> some View {
        MiniPlayerAccessoryView(showingFullPlayer: $showingFullPlayer,
            onOpenLyrics: { presentFullPlayer(lyrics: true, queue: false) },
            onOpenQueue: { presentFullPlayer(lyrics: false, queue: true) },
            usesSystemAccessory: usesSystemAccessory)
            .cassetteMatchedTransitionSource(id: fullPlayerZoomID, in: playerZoom)
    }

    private func presentFullPlayer(lyrics: Bool, queue: Bool) {
        openPlayerWithLyrics = lyrics
        openPlayerWithQueue = queue
        showingFullPlayer = true
    }

    private func resetFullPlayerLaunchFlags() {
        openPlayerWithLyrics = false
        openPlayerWithQueue = false
    }

    private func fullPlayerDidDismiss() {
        resetFullPlayerLaunchFlags()
        guard let request = pendingNavigation else { return }
        pendingNavigation = nil
        switch request.mode {
        case .replace: performNavigation(to: request.destination, tab: request.tab)
        case .append: appendDestination(request.destination, to: request.tab)
        }
    }

    private func handleNavigateToArtist(_ note: Notification) {
        guard let id = note.userInfo?["artistId"] as? String else { return }
        let name = note.userInfo?["artistName"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        // One token per tap. `HomeDestination` artist values are equal by content, and NavigationStack maps
        // an equal path value onto the entry that already holds it — an artist already in the path would be
        // reused (pop, not push) and the back button would point at a removed entry. Created here so it
        // stays stable for the life of the entry.
        let dest = HomeDestination.artistPush(id: id, name: name, coverArtId: cover, token: UUID())
        // Push into the tab the user is looking at (the player covers it) so Back returns to the page they
        // came from instead of dropping the whole path.
        navigateAppending(to: dest, tab: selectedTab)
    }

    private func handleNavigateToAlbum(_ note: Notification) {
        guard let id = note.userInfo?["albumId"] as? String else { return }
        let name = note.userInfo?["albumName"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        let dest = HomeDestination.albumById(id: id, name: name, subtitle: "", coverArtId: cover)
        navigateReplacingPath(to: dest, tab: .home)
    }

    private func handleNavigateToPlaylist(_ note: Notification) {
        guard let id = note.userInfo?["playlistId"] as? String else { return }
        let name = note.userInfo?["name"] as? String ?? ""
        let cover = note.userInfo?["coverArtId"] as? String
        let dest = HomeDestination.playlistById(id: id, name: name, coverArtId: cover)
        navigateReplacingPath(to: dest, tab: .library)
    }

    /// Dismiss the player first, then navigate from its real completion callback. A fixed
    /// delay races the full-screen dismissal animation and can leave the destination under
    /// a stale black presentation layer.
    private func navigateReplacingPath(to destination: HomeDestination, tab: AppTab) {
        if showingFullPlayer {
            pendingNavigation = (destination, tab, .replace)
            showingFullPlayer = false
        } else {
            performNavigation(to: destination, tab: tab)
        }
    }

    /// Pushes the destination onto the tab the user is in, after any presentation has fully gone.
    private func navigateAppending(to destination: HomeDestination, tab: AppTab) {
        if showingFullPlayer {
            pendingNavigation = (destination, tab, .append)
            showingFullPlayer = false
        } else {
            appendDestination(destination, to: tab)
        }
    }

    private func performNavigation(to destination: HomeDestination, tab: AppTab) {
        selectedTab = tab
        applyingAfterPresentationsSettle {
            // Give TabView one update cycle to mount the selected NavigationStack.
            await Task.yield()
            var path = NavigationPath()
            path.append(destination)
            replacePath(path, in: tab)
        }
    }

    private func appendDestination(_ destination: HomeDestination, to tab: AppTab) {
        applyingAfterPresentationsSettle {
            await Task.yield()
            appendPath(destination, in: tab)
        }
    }

    /// A zoom-dismissed cover (and any closing sheet) keeps its presentation layer on top for a runloop or
    /// two after `onDismiss`, and the tab's stack only mounts on the following update cycle. Mutating a
    /// NavigationPath in that window leaves the pushed page under that stale layer: it renders blank (or
    /// black) and taps on the back button never reach it. Wait until UIKit reports no presented controller,
    /// then apply the change on the next main-queue pass. Bounded so a stuck presentation cannot block
    /// navigation forever.
    private func applyingAfterPresentationsSettle(_ change: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            #if os(iOS)
            var attempts = 0
            while Self.hasPresentedViewController(), attempts < 40 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            #endif
            await Task.yield()
            await change()
        }
    }

    private func replacePath(_ path: NavigationPath, in tab: AppTab) {
        Logger.ui.debug("[NAV] replace requested tab=\(String(describing: tab), privacy: .public) count=\(path.count, privacy: .public)")
        switch tab {
        case .home: homePath = path
        case .library: libraryPath = path
        case .discover: discoverPath = path
        case .search: searchPath = path
        case .recentlyAdded: recentlyAddedPath = path
        case .artists: artistsPath = path
        case .albums: albumsPath = path
        case .favorites: favoritesPath = path
        case .playlists: playlistsPath = path
        case .downloads: downloadsPath = path
        }
    }

    private func appendPath(_ destination: HomeDestination, in tab: AppTab) {
        Logger.ui.debug("[NAV] append requested tab=\(String(describing: tab), privacy: .public)")
        switch tab {
        case .home: homePath.append(destination)
        case .library: libraryPath.append(destination)
        case .discover: discoverPath.append(destination)
        case .search: searchPath.append(destination)
        case .recentlyAdded: recentlyAddedPath.append(destination)
        case .artists: artistsPath.append(destination)
        case .albums: albumsPath.append(destination)
        case .favorites: favoritesPath.append(destination)
        case .playlists: playlistsPath.append(destination)
        case .downloads: downloadsPath.append(destination)
        }
    }


    #if os(iOS)
    /// True while any view controller sits above the key window's root (the full player's cover, a sheet, an
    /// alert…). The path change must wait for it to go.
    private static func hasPresentedViewController() -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        var controller = root
        while let presented = controller.presentedViewController { controller = presented }
        return controller !== root
    }
    #endif
#endif
}
