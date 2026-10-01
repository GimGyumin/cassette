// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftSonic

struct ArtistsListMacOS: View {
    @Environment(\.appContainer) private var container
    @State private var vm: ArtistListViewModel?
    @AppStorage("cassette.artistSort") private var artistSort: ArtistSort = .name

    var body: some View {
        Group {
            if let vm {
                artistsContent(vm)
            } else {
                LoadingStateView()
            }
        }
        .navigationTitle("Artists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ArtistSortMenu(sort: $artistSort)
            }
        }
        .task(id: container?.serverState.isOnline) {
            guard let svc = container?.libraryService else { return }
            if vm == nil { vm = ArtistListViewModel(libraryService: svc) }
            guard container?.serverState.isOnline == true else { return }
            await vm?.load()
        }
    }

    @ViewBuilder
    private func artistsContent(_ vm: ArtistListViewModel) -> some View {
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
            let allArtists = artistSort.sorted(vm.indexes.flatMap(\.artist))
            GeometryReader { geo in
                let count = Self.gridColumnCount(for: geo.size.width)
                let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: count)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 32) {
                            if artistSort == .name {
                                ForEach(alphabetGroups(from: allArtists), id: \.letter) { group in
                                    Section {
                                        ForEach(group.artists) { artist in
                                            artistLink(artist)
                                        }
                                    } header: {
                                        HStack {
                                            Text(group.letter)
                                                .font(.title2.bold())
                                            Spacer()
                                        }
                                        .id(group.letter)
                                    }
                                }
                            } else {
                                ForEach(allArtists) { artist in
                                    artistLink(artist)
                                }
                            }
                        }
                        .padding(24)
                    }
                    .refreshable { await vm.load() }
                    .safeAreaInset(edge: .trailing, spacing: 0) {
                        if artistSort == .name {
                            let letters = Set(alphabetGroups(from: allArtists).map(\.letter))
                            if letters.count >= 5 {
                                AlphabetJumpBar(
                                    availableLetters: letters,
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
        }
    }

    private func artistLink(_ artist: ArtistID3) -> some View {
        NavigationLink(value: HomeDestination.artist(artist)) {
            ArtistGridCard(artist: artist)
        }
        .buttonStyle(.plain)
        .artistLongPressMenu(artist)
        .id(artist.id)
    }

    private func alphabetGroups(from artists: [ArtistID3]) -> [(letter: String, artists: [ArtistID3])] {
        let grouped = Dictionary(grouping: artists) { artist in
            alphabetFirstLetter(of: artist.sortName ?? artist.name)
        }
        return grouped
            .map { (letter: $0.key, artists: $0.value) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" { return false }
                if rhs.letter == "#" { return true }
                return lhs.letter.localizedStandardCompare(rhs.letter) == .orderedAscending
            }
    }

    private static func gridColumnCount(for width: CGFloat) -> Int {
        switch width {
        case ..<900:  return 3
        case ..<1200: return 4
        case ..<1600: return 5
        default:      return 6
        }
    }
}
#endif
