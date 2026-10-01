// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic

struct ArtistListView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: ArtistListViewModel?
    @State private var searchText = ""
    @State private var artistFilter: ArtistLibraryFilter
    @AppStorage("cassette.artistSort") private var artistSort: ArtistSort = .name
    @Query private var favorites: [FavoriteRecord]
    @Query private var downloadedTracks: [DownloadedTrack]

    init(initialFilter: ArtistLibraryFilter = .all) {
        _artistFilter = State(initialValue: initialFilter)
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                browseContent(vm)
            } else {
                LoadingStateView()
            }
        }
        .cassetteContentWidth()
        .navigationTitle(String(localized: "Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .navigationBarTitleDisplayModeLarge()
        .cassetteLibrarySearch(
            text: $searchText,
            prompt: String(localized: "Search Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Artists", selection: $artistFilter) {
                        ForEach(ArtistLibraryFilter.allCases, id: \.self) { filter in
                            Label(filter.label, systemImage: filter.systemImage).tag(filter)
                        }
                    }
                    Divider()
                    Picker("Sort By", selection: $artistSort) {
                        ForEach(ArtistSort.allCases, id: \.self) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Sort artists")
            }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil { viewModel = ArtistListViewModel(libraryService: svc) }
            guard container?.serverState.isOnline == true else { return }
            await viewModel?.load()
        }
    }

    @ViewBuilder
    private func browseContent(_ vm: ArtistListViewModel) -> some View {
        if vm.isLoading && vm.indexes.isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && vm.indexes.isEmpty {
            if let serverId = container?.serverState.activeServer?.id {
                OfflineBrowseContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "You're Offline",
                    subtitle: "Connect to your server to browse artists."
                )
            }
        } else if let error = vm.error, vm.indexes.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Artists",
                subtitle: error.displayMessage,
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.indexes.isEmpty {
            EmptyStateView(
                systemImage: "music.mic",
                title: "No Artists",
                subtitle: "Your library appears to be empty."
            )
        } else {
            let sections = displayedSections(from: vm.indexes)
            ScrollViewReader { proxy in
                List {
                    if sections.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.artists) { artist in
                                NavigationLink(value: HomeDestination.artist(artist)) {
                                    ArtistRow(artist: artist)
                                }
                                .artistLongPressMenu(artist)
                            }
                        }
                        .id(section.id)
                    }
                }
                .listStyle(.plain)
                .refreshable { await vm.load() }
                .miniPlayerBottomMargin()
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if sections.count >= 5 && artistSort == .name {
                        AlphabetJumpBar(
                            availableLetters: Set(sections.map(\.title)),
                            onLetterTap: { letter in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            }
                        )
                        .padding(.trailing, 4)
                    }
                }
            }
        }
    }

    private func displayedSections(from indexes: [ArtistIndex]) -> [ArtistDisplaySection] {
        let allArtists = indexes.flatMap(\.artist)
        let sourceIds: Set<String>? = {
            guard let serverId = container?.serverState.activeServer?.id else { return nil }
            switch artistFilter {
            case .all:
                return nil
            case .favorites:
                return Set(favorites.lazy.filter {
                    $0.serverId == serverId && $0.itemType == FavoriteType.artist.rawValue
                }.map(\.itemId))
            case .downloads:
                return Set(downloadedTracks.lazy.filter { $0.serverId == serverId }.compactMap(\.artistId))
            }
        }()
        let downloadedNames: Set<String> = {
            guard artistFilter == .downloads,
                  let serverId = container?.serverState.activeServer?.id else { return [] }
            return Set(downloadedTracks.lazy.filter { $0.serverId == serverId }.compactMap(\.artist))
        }()
        let scoped = sourceIds.map { ids in
            allArtists.filter { ids.contains($0.id) || downloadedNames.contains($0.name) }
        } ?? allArtists
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? scoped : scoped.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        let sorted = artistSort.sorted(filtered)

        guard artistSort == .name else {
            return sorted.isEmpty ? [] : [ArtistDisplaySection(id: "all", title: "Artists", artists: sorted)]
        }

        let grouped = Dictionary(grouping: sorted) { artist -> String in
            guard let first = (artist.sortName ?? artist.name).trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
            let letter = String(first).uppercased()
            return letter.rangeOfCharacter(from: .letters) == nil ? "#" : letter
        }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ArtistDisplaySection(id: $0, title: $0, artists: grouped[$0] ?? []) }
    }
}

enum ArtistLibraryFilter: String, CaseIterable {
    case all
    case favorites
    case downloads

    var label: String {
        switch self {
        case .all: return "All Artists"
        case .favorites: return "Favorites"
        case .downloads: return "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "music.mic"
        case .favorites: return "star"
        case .downloads: return "arrow.down.circle"
        }
    }
}

private struct ArtistDisplaySection: Identifiable {
    let id: String
    let title: String
    let artists: [ArtistID3]
}

// MARK: - Offline Browse

nonisolated struct OfflineAlbumSummary: Sendable, Identifiable, Hashable {
    let albumId: String
    let albumName: String
    let artistName: String?
    let coverArtId: String?
    let trackCount: Int
    var id: String { albumId }
}

nonisolated struct OfflineArtistSummary: Sendable, Identifiable, Hashable {
    let name: String
    let albums: [OfflineAlbumSummary]
    var id: String { name }
}

/// Derives the offline artist/album hierarchy from DownloadedTrack — the single source of truth
/// for all offline content, regardless of whether it came from an album or a playlist download.
struct OfflineBrowseContent: View {
    let serverId: UUID
    @Query private var tracks: [DownloadedTrack]

    init(serverId: UUID) {
        self.serverId = serverId
        let sid = serverId
        _tracks = Query(
            filter: #Predicate<DownloadedTrack> { track in track.serverId == sid }
        )
    }

    private var artistSummaries: [OfflineArtistSummary] {
        let withAlbum = tracks.filter { $0.albumId != nil }
        let byAlbum = Dictionary(grouping: withAlbum) { $0.albumId! }
        let albumSummaries = byAlbum.map { albumId, albumTracks -> OfflineAlbumSummary in
            let first = albumTracks[0]
            return OfflineAlbumSummary(
                albumId: albumId,
                albumName: first.album ?? albumId,
                artistName: first.artist,
                coverArtId: first.coverArtId,
                trackCount: albumTracks.count
            )
        }
        let byArtist = Dictionary(grouping: albumSummaries) { $0.artistName ?? "Unknown Artist" }
        return byArtist.map { name, albums in
            OfflineArtistSummary(
                name: name,
                albums: albums.sorted { $0.albumName < $1.albumName }
            )
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        if tracks.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "No downloaded music available. Download albums or playlists while online to listen offline."
            )
        } else {
            List {
                Section("Downloaded Artists") {
                    ForEach(artistSummaries) { artist in
                        NavigationLink(value: HomeDestination.offlineArtist(artist)) {
                            HStack(spacing: CassetteSpacing.m) {
                                Image(systemName: "music.mic")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(CassetteColors.accentBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.s))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name)
                                        .font(.cassetteCellTitle)
                                        .lineLimit(1)
                                    Text(CassetteCountLabel.albums(artist.albums.count))
                                        .font(.cassetteCaption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, CassetteSpacing.xs)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

struct OfflineArtistAlbumsView: View {
    let artist: OfflineArtistSummary

    var body: some View {
        List {
            ForEach(artist.albums) { album in
                NavigationLink(value: HomeDestination.offlineAlbum(album)) {
                    AlbumRow(
                        albumId: album.albumId,
                        name: album.albumName,
                        artist: album.artistName,
                        year: nil,
                        coverArtId: album.coverArtId
                    )
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomMargin()
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayModeInline()
        .cassetteContentWidth()
    }
}
