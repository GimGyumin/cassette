import SwiftUI
import OSLog

struct SearchResultsList: View {
    let viewModel: SearchViewModel
    let category: SearchCategory
    let query: String
    let showsSuggestions: Bool
    let downloadsOnly: Bool
    let onSuggestion: (String) -> Void
    let onRetry: () async -> Void

    @Environment(\.appContainer) private var container
    @State private var songToAdd: DisplayableSong?

    private var items: [SearchResultItem] {
        var result: [SearchResultItem] = []
        let filter: SearchCategory = showsSuggestions && !downloadsOnly ? .all : category
        if filter == .all || filter == .songs { result += viewModel.songs.map(SearchResultItem.song) }
        if filter == .all || filter == .artists { result += viewModel.artists.map(SearchResultItem.artist) }
        if filter == .all || filter == .albums { result += viewModel.albums.map(SearchResultItem.album) }
        if filter == .all || filter == .playlists { result += viewModel.localHits.playlists.map(SearchResultItem.playlist) }
        // Mix result kinds by title relevance; preserve server order for equal scores.
        if filter == .all {
            result = result.enumerated().sorted {
                let left = relevance($0.element.title)
                let right = relevance($1.element.title)
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
        }
        return result
    }

    private func relevance(_ title: String) -> Int {
        let name = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppUILanguage.locale)
        let term = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: AppUILanguage.locale)
        return name == term ? 3 : name.hasPrefix(term) ? 2 : name.contains(term) ? 1 : 0
    }

    var body: some View {
        let rows = items
        List {
            if showsSuggestions {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button { onSuggestion(suggestion) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass").font(.title2)
                            Text(suggestion).font(.title3).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if viewModel.isLocalOnly && !downloadsOnly {
                Text(String(localized: "Searching downloads and indexed music. The server is unreachable.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { item in
                resultRow(item)
                    .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 74 }
            }
            if viewModel.isSearching || viewModel.isIndexing {
                progressRow
            } else if let error = viewModel.searchError {
                VStack(spacing: 10) {
                    Text(error.localizedDescription).font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") {
                        Task {
                            if viewModel.searchResults == nil { await onRetry() }
                            else { await viewModel.loadMore(category: category) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            } else if rows.isEmpty {
                EmptyStateView(systemImage: "magnifyingglass", title: "No results", subtitle: "Try a different search term.")
                    .listRowSeparator(.hidden)
            }
            if viewModel.canLoadMore(category), viewModel.searchError == nil {
                Button {
                    Task { await viewModel.loadMore(category: category) }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isLoadingMore { ProgressView() }
                        else { Text(String(localized: "Load More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                }
                .disabled(viewModel.isLoadingMore)
                .listRowSeparator(.hidden)
                .onAppear { Task { await viewModel.loadMore(category: category) } }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $songToAdd) { AddToPlaylistSheet(song: $0) }
    }

    private var progressRow: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.vertical, 18).listRowSeparator(.hidden)
    }

    @ViewBuilder private func resultRow(_ item: SearchResultItem) -> some View {
        switch item {
        case .song(let song):
            HStack(spacing: 0) {
                Button { play(song) } label: { SearchResultLabel(item: item) }
                    .buttonStyle(.plain)
                Menu {
                    Button("Play", systemImage: "play.fill") { play(song) }
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        Task { await container?.playerService.playNext(song) }
                    }
                    Button("Add to Queue", systemImage: "text.badge.plus") {
                        Task { await container?.playerService.addToQueue(song) }
                    }
                    Button("Add to Playlist…", systemImage: "music.note.list") { songToAdd = song }
                } label: {
                    Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(String(localized: "More Options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .accessibilityValue(song.title)
            }
            .songLongPressMenu(song)
        case .artist(let artist):
            NavigationLink(value: SearchHistoryNavTarget(itemId: artist.id, itemType: "artist", displayName: artist.name, coverArtId: artist.coverArtId)) {
                SearchResultLabel(item: item)
            }
        case .album(let album):
            NavigationLink(value: SearchHistoryNavTarget(itemId: album.id, itemType: "album", displayName: album.name, coverArtId: album.coverArtId)) {
                SearchResultLabel(item: item)
            }
            .albumLongPressMenu(id: album.id, name: album.name, coverArtId: album.coverArtId)
        case .playlist(let playlist):
            NavigationLink { PlaylistDetailView(playlistId: playlist.id, name: playlist.name) } label: {
                SearchResultLabel(item: item)
            }
            .playlistLongPressMenu(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArtId)
        }
    }

    private func play(_ song: DisplayableSong) {
        let songs = viewModel.songs
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        Task {
            do { try await container?.playerService.play(tracks: songs, startIndex: index) }
            catch { Logger.player.error("[SEARCH] play failed: \(error, privacy: .public)") }
        }
    }
}
