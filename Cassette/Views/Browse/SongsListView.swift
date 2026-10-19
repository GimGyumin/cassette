// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

struct SongsListView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: SongsListViewModel?
    @State private var sourceAccountRevision: UInt64?
    @State private var songToAddToPlaylist: DisplayableSong?
    @State private var searchText = ""
    /// Ordering is persisted (like `cassette.albumSort` / `cassette.artistSort`); the source filter is
    /// session-scoped so the screen always opens on the full library.
    @AppStorage("cassette.songSort") private var songSort: SongSort = .title
    @State private var songFilter: SongListFilter

    init(initialFilter: SongListFilter = .allSongs) {
        _songFilter = State(initialValue: initialFilter)
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                LoadingStateView()
            }
        }
        .cassetteContentWidth()
        .navigationTitle(String(localized: "Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .navigationBarTitleDisplayModeLarge()
        .cassetteLibrarySearch(
            text: $searchText,
            prompt: String(localized: "Search Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        )
        .toolbar {
            ToolbarItem(placement: songsToolbarPlacement) {
                SongSortMenu(sort: $songSort)
            }
            ToolbarItem(placement: songsToolbarPlacement) {
                SongFilterMenu(filter: $songFilter)
            }
        }
        .task(id: "\(container?.serverState.accountRevision ?? 0)|\(container?.serverState.isOnline == true)") {
            guard let svc = container?.libraryService else { return }
            if viewModel == nil || sourceAccountRevision != container?.serverState.accountRevision {
                sourceAccountRevision = container?.serverState.accountRevision
                let vm = SongsListViewModel(
                    libraryService: svc,
                    modelContainer: container?.modelContainer,
                    serverState: container?.serverState,
                    downloadService: container?.downloadService
                )
                viewModel = vm
                vm.setSort(songSort)
                if songFilter == .allSongs {
                    guard container?.serverState.isOnline == true else { return }
                    await vm.load()
                } else {
                    await vm.setFilter(songFilter)
                }
                return
            }
            guard container?.serverState.isOnline == true || songFilter == .downloads else { return }
            await viewModel?.load()
            viewModel?.setSort(songSort)
        }
        .onChange(of: songSort) { _, newSort in
            viewModel?.setSort(newSort)
        }
        .onChange(of: songFilter) { _, newFilter in
            Task { await viewModel?.setFilter(newFilter) }
        }
    }

    /// The sort + filter controls sit together in the trailing toolbar on iOS and the primary-action
    /// group on macOS.
    private var songsToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    @ViewBuilder
    private func content(_ vm: SongsListViewModel) -> some View {
        if (vm.isLoading || vm.isLoadingFilterSource) && vm.allSongs.isEmpty {
            LoadingStateView()
        } else if container?.serverState.isOnline == false && vm.filter != .downloads && vm.allSongs.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                subtitle: "Connect to your server to browse songs."
            )
        } else if let error = vm.error, vm.allSongs.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Unable to Load Songs",
                subtitle: error.displayMessage,
                action: .init(label: "Retry") { Task { await vm.load() } }
            )
        } else if vm.allSongs.isEmpty {
            emptyState(for: vm.filter)
        } else {
            songsList(vm)
        }
    }

    /// Filter-specific "nothing here" copy — the toolbar menus stay reachable so the user can switch back.
    @ViewBuilder
    private func emptyState(for filter: SongListFilter) -> some View {
        switch filter {
        case .allSongs:
            EmptyStateView(
                systemImage: "music.note",
                title: "No Songs",
                subtitle: "Your library appears to be empty."
            )
        case .favorites:
            EmptyStateView(
                systemImage: "star",
                title: "No Favorites",
                subtitle: "Songs you favorite will appear here."
            )
        case .downloads:
            EmptyStateView(
                systemImage: "arrow.down.circle",
                title: "Nothing Downloaded",
                subtitle: "Music you download for offline listening will appear here."
            )
        }
    }

    private func songsList(_ vm: SongsListViewModel) -> some View {
        let songs = displayedSongs(vm.allSongs)
        let sections = displayedSections(songs, sort: songSort)
        return ScrollViewReader { proxy in
            List {
                Section {
                    playShuffleHeader(songs)
                }

                if songs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowSeparator(.hidden)
                } else if songSort.groupsAlphabetically {
                    ForEach(sections) { section in
                        Section {
                            ForEach(Array(section.songs.enumerated()), id: \.element.id) { index, song in
                                songRow(song, globalIndex: section.startIndex + index, songs: songs, vm: vm)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                        .id(section.letter)
                        .cassetteSectionIndexLabel(section.letter)
                    }
                } else {
                    // "Date Added" is one newest-first list — no letter headers, no jump bar.
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        songRow(song, globalIndex: index, songs: songs, vm: vm)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await vm.load() }
            .miniPlayerBottomMargin()
            .cassetteSoftTopScrollEdge()
            .cassetteListIndex(letters: Set(sections.map(\.letter)),
                isVisible: songSort.groupsAlphabetically && songs.count >= 20) { letter in
                proxy.scrollTo(letter, anchor: .top)
            }
            .sheet(item: $songToAddToPlaylist) { song in
                AddToPlaylistSheet(song: song)
            }
        }
    }

    /// Row with cover art + trailing “…” menu (no duration), tappable to play from that song.
    /// Uses `onTapGesture` — not a wrapping `Button` — so the nested Menu keeps its own taps.
    @ViewBuilder
    private func songRow(
        _ song: DisplayableSong,
        globalIndex: Int,
        songs: [DisplayableSong],
        vm: SongsListViewModel
    ) -> some View {
        Group {
            SongRow(
                song: song,
                index: globalIndex + 1,
                showCoverArt: true,
                onAddToPlaylist: { s in songToAddToPlaylist = s },
                showsEllipsisInsteadOfDuration: true
            )
            .contentShape(Rectangle())
        }
        .onTapGesture {
            play(from: globalIndex, songs: songs)
        }
        .accessibilityAction {
            play(from: globalIndex, songs: songs)
        }
        .onAppear {
            if searchText.isEmpty && globalIndex >= vm.allSongs.count - 10 {
                Task { await vm.loadMoreIfNeeded() }
            }
        }
    }

    private func play(from index: Int, songs: [DisplayableSong]) {
        guard songs.indices.contains(index) else { return }
        Task {
            try? await container?.playerService.play(tracks: songs, startIndex: index)
        }
    }

    @ViewBuilder
    private func playShuffleHeader(_ songs: [DisplayableSong]) -> some View {
        if !songs.isEmpty {
            HStack(spacing: CassetteSpacing.m) {
                Button {
                    Task {
                        try? await container?.playerService.play(tracks: songs, startIndex: 0)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .foregroundStyle(Color.cassetteAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .cassetteGlassCapsule()
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        let idx = Int.random(in: 0..<songs.count)
                        try? await container?.playerService.play(tracks: songs, startIndex: idx)
                        if container?.playerState.isShuffled != true {
                            await container?.playerService.toggleShuffle()
                        }
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .foregroundStyle(Color.cassetteAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .cassetteGlassCapsule()
                }
                .buttonStyle(.plain)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.vertical, CassetteSpacing.xs)
        }
    }

    private func displayedSongs(_ songs: [DisplayableSong]) -> [DisplayableSong] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.artist?.localizedCaseInsensitiveContains(query) == true)
                || ($0.albumName?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private func displayedSections(_ songs: [DisplayableSong], sort: SongSort) -> [SongAlphabetSection] {
        guard sort.groupsAlphabetically else { return [] }
        let grouped = Dictionary(grouping: songs) { song -> String in
            let value = sort.groupingKey(for: song).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = value.first else { return "#" }
            let letter = String(first).uppercased()
            return letter.rangeOfCharacter(from: .letters) == nil ? "#" : letter
        }
        var offset = 0
        return grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { letter in
            let sectionSongs = grouped[letter] ?? []
            defer { offset += sectionSongs.count }
            return SongAlphabetSection(letter: letter, songs: sectionSongs, startIndex: offset)
        }
    }
}
