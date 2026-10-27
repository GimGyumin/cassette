// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct AlbumsListView: View {
    @Namespace private var albumNamespace
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: AlbumListViewModel?
    @State private var searchText = ""
    @State private var albumFilter: AlbumLibraryFilter
    @AppStorage("cassette.albumSort") private var albumSort: AlbumSort = .name
    @AppStorage("cassette.albumLayout") private var albumLayout: AlbumLayout = .grid
    @Query private var favorites: [FavoriteRecord]
    @Query private var downloadedAlbums: [DownloadedAlbum]
    @Query private var downloadedTracks: [DownloadedTrack]

    init(initialFilter: AlbumLibraryFilter = .albums) {
        _albumFilter = State(initialValue: initialFilter)
    }

    private var usesAlbumGrid: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular || albumLayout == .grid
        #endif
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .navigationTitle(String(localized: "Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .navigationBarTitleDisplayModeLarge()
        .cassetteLibrarySearch(
            text: $searchText,
            prompt: String(localized: "Search Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    #if os(iOS)
                    Picker("View", selection: $albumLayout) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(AlbumLayout.grid)
                        Label("List", systemImage: "list.bullet").tag(AlbumLayout.list)
                    }
                    Divider()
                    #endif
                    Picker("Sort By", selection: $albumSort) {
                        ForEach(AlbumSort.allCases, id: \.self) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: usesAlbumGrid ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityLabel("Album view and sorting")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Albums", selection: $albumFilter) {
                        ForEach(AlbumLibraryFilter.allCases, id: \.self) { filter in
                            Label(filter.label, systemImage: filter.systemImage).tag(filter)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Filter albums")
            }
        }
        .task(id: container?.serverState.isOnline) {
            Logger.boot.notice("🟢 AlbumsListView task fired — activeServer=\(String(describing: container?.serverState.activeServer?.baseURL), privacy: .public) isOnline=\(String(describing: container?.serverState.isOnline), privacy: .public)")
            guard let svc = container?.libraryService else {
                Logger.boot.error("🔴 AlbumsListView: container?.libraryService is nil — skipping")
                return
            }
            if viewModel == nil { viewModel = AlbumListViewModel(libraryService: svc) }
            guard container?.serverState.isOnline == true else {
                Logger.boot.notice("🟡 AlbumsListView: isOnline=false — skipping load")
                return
            }
            await viewModel?.load()
            // Detect changed album covers since last launch when the Albums page is opened.
            container?.albumCoverPreloadService.reconcileChangedCovers()
        }
    }

    @ViewBuilder
    private func content(_ vm: AlbumListViewModel) -> some View {
        if vm.isLoading && vm.albums.isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && vm.albums.isEmpty {
            if let serverId = container?.serverState.activeServer?.id {
                OfflineAlbumsContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "You're Offline",
                    subtitle: "Connect to your server to browse albums."
                )
            }
        } else if let error = vm.error, vm.albums.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Albums",
                subtitle: error.displayMessage,
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.albums.isEmpty {
            EmptyStateView(
                systemImage: "square.stack",
                title: "No Albums",
                subtitle: "Your library appears to be empty."
            )
        } else if usesAlbumGrid {
            albumsGrid(vm)
        } else {
            albumsList(vm)
        }
    }

    @ViewBuilder
    private func albumsGrid(_ vm: AlbumListViewModel) -> some View {
        GeometryReader { geo in
            let count = Self.gridColumnCount(for: geo.size.width)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
            let albums = displayedAlbums(vm.albums)
            ScrollView {
                VStack(spacing: CassetteSpacing.m) {
                    playShuffleHeader(albums: albums)
                    if albums.isEmpty {
                        emptyFilteredAlbums
                            .padding(.top, CassetteSpacing.xl)
                    } else {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(albums) { album in
                                AlbumNavigationLink(album: album, namespace: albumNamespace) { sourceID, namespace in
                                    AlbumGridCell(album: album, zoomSourceId: sourceID, zoomNamespace: namespace)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, CassetteSpacing.s)
            }
            .refreshable { await vm.load() }
            .miniPlayerBottomMargin()
            .cassetteSoftTopScrollEdge()
        }
    }

    @ViewBuilder
    private func albumsList(_ vm: AlbumListViewModel) -> some View {
        let albums = displayedAlbums(vm.albums)
        ScrollViewReader { proxy in
            List {
                Section {
                    playShuffleHeader(albums: albums)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if albums.isEmpty {
                    emptyFilteredAlbums
                        .listRowSeparator(.hidden)
                }

                if albumSort == .name {
                    ForEach(indexedAlbums(albums)) { section in
                        Section { albumRows(section.albums) }
                            .cassetteSectionIndexLabel(section.letter)
                    }
                } else {
                    albumRows(albums)
                }
            }
            .listStyle(.plain)
            .refreshable { await vm.load() }
            .miniPlayerBottomMargin()
            .cassetteSoftTopScrollEdge()
            .cassetteListIndex(letters: albums.availableAlphabetLetters(keyPath: \.name),
                isVisible: albums.count >= 20 && albumSort == .name) { letter in
                if let id = firstAlphabetItemID(forLetter: letter, in: albums, keyPath: \.name) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    private struct AlbumIndexSection: Identifiable {
        let id: String
        let letter: String
        var albums: [AlbumID3]
    }

    private func indexedAlbums(_ albums: [AlbumID3]) -> [AlbumIndexSection] {
        // Preserve the selected locale's existing sort order, including non-Latin names.
        albums.reduce(into: []) { sections, album in
            let letter = alphabetFirstLetter(of: album.name)
            if sections.last?.letter == letter {
                sections[sections.count - 1].albums.append(album)
            } else {
                sections.append(AlbumIndexSection(id: album.id, letter: letter, albums: [album]))
            }
        }
    }

    private func albumRows(_ albums: [AlbumID3]) -> some View {
        ForEach(albums) { album in
            AlbumNavigationLink(album: album, namespace: albumNamespace) { sourceID, namespace in
                AlbumRow(albumId: album.id, name: album.name, artist: album.artist,
                    year: album.year, coverArtId: album.coverArt, zoomSourceId: sourceID, zoomNamespace: namespace)
            }
            .id(album.id)
        }
    }

    private func displayedAlbums(_ albums: [AlbumID3]) -> [AlbumID3] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIds: Set<String>? = {
            guard let serverId = container?.serverState.activeServer?.id else { return nil }
            switch albumFilter {
            case .albums, .compilations, .all:
                return nil
            case .favorites:
                return Set(favorites.lazy.filter { $0.serverId == serverId && $0.itemType == FavoriteType.album.rawValue }.map(\.itemId))
            case .downloads:
                let recordIds = downloadedAlbums.lazy.filter { $0.serverId == serverId }.map(\.albumId)
                let trackIds = downloadedTracks.lazy.filter { $0.serverId == serverId }.compactMap(\.albumId)
                return Set(recordIds).union(trackIds)
            }
        }()
        let scoped = sourceIds.map { ids in albums.filter { ids.contains($0.id) } } ?? albums
        let categorized = scoped.filter(albumFilter.includes)
        let filtered = query.isEmpty ? categorized : categorized.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.artist?.localizedCaseInsensitiveContains(query) == true)
        }
        return albumSort.sorted(filtered)
    }

    @ViewBuilder
    private var emptyFilteredAlbums: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if albumFilter == .compilations {
            ContentUnavailableView {
                Label("Compilations", systemImage: "square.stack.3d.up")
            } description: {
                Text("No compilations in the library.")
            }
        } else {
            ContentUnavailableView("No Albums", systemImage: "square.stack")
        }
    }

    @ViewBuilder
    private func playShuffleHeader(albums: [AlbumID3]) -> some View {
        if !albums.isEmpty {
            HStack(spacing: CassetteSpacing.m) {
                libraryAction(title: "Play", systemImage: "play.fill") {
                    playFirstAlbum(in: albums)
                }
                libraryAction(title: "Shuffle", systemImage: "shuffle") {
                    shuffleLibrary()
                }
            }
        }
    }

    private func libraryAction(title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.cassetteAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .cassetteGlassCapsule()
        }
        .buttonStyle(.plain)
    }

    private func playFirstAlbum(in albums: [AlbumID3]) {
        guard let first = albums.first else { return }
        Task {
            guard let detail = try? await container?.libraryService.album(id: first.id),
                  let songs = detail.song, !songs.isEmpty else { return }
            try? await container?.playerService.play(tracks: songs.map { DisplayableSong(from: $0) }, startIndex: 0)
        }
    }

    private func shuffleLibrary() {
        Task {
            guard let songs = try? await container?.libraryService.randomSongs(size: 100), !songs.isEmpty else { return }
            try? await container?.playerService.play(tracks: songs.map { DisplayableSong(from: $0) }, startIndex: 0)
            if container?.playerState.isShuffled != true {
                await container?.playerService.toggleShuffle()
            }
        }
    }

    private static func gridColumnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<600:  return 2
        case ..<900:  return 3
        case ..<1200: return 4
        case ..<1600: return 5
        default:      return 6
        }
    }
}

enum AlbumLibraryFilter: String, CaseIterable {
    case albums
    case compilations
    case all
    case favorites
    case downloads

    func includes(_ album: AlbumID3) -> Bool {
        switch self {
        case .albums: return ArtistAlbumCategorizer.classify(album) != .compilations
        case .compilations: return ArtistAlbumCategorizer.classify(album) == .compilations
        case .all, .favorites, .downloads: return true
        }
    }

    var label: String {
        switch self {
        case .albums: return "Albums"
        case .compilations: return "Compilations"
        case .all: return "All Albums"
        case .favorites: return "Favorites"
        case .downloads: return "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: return "square.stack"
        case .compilations: return "square.stack.3d.up"
        case .all: return "square.stack"
        case .favorites: return "star"
        case .downloads: return "arrow.down.circle"
        }
    }
}

private enum AlbumLayout: String {
    case grid
    case list
}

// MARK: - Offline Albums

private struct OfflineAlbumsContent: View {
    let serverId: UUID
    @Query private var albums: [DownloadedAlbum]
    @Query private var tracks: [DownloadedTrack]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _albums = Query(
            filter: #Predicate<DownloadedAlbum> { album in album.serverId == sid },
            sort: [SortDescriptor(\DownloadedAlbum.name)]
        )
        _tracks = Query(filter: #Predicate<DownloadedTrack> { track in track.serverId == sid })
    }

    private var displayAlbums: [DownloadedAlbumDisplay] {
        DownloadedAlbumMerger.merge(records: albums, tracks: tracks)
    }

    var body: some View {
        if displayAlbums.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "No downloaded albums available. Download albums while online to listen offline."
            )
        } else {
            List {
                Section("Downloaded Albums") {
                    ForEach(displayAlbums) { display in
                        NavigationLink(value: HomeDestination.downloadedAlbum(display)) {
                            AlbumRow(
                                albumId: display.albumId,
                                name: display.name,
                                artist: display.artist,
                                year: nil,
                                coverArtId: display.coverArtId
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
