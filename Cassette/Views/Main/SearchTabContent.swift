import SwiftUI
import SwiftSonic

/// All changing search state stays below SearchView's navigation destination shell.
struct SearchTabContent: View {
    @Binding var path: NavigationPath
    var externalSearchQuery: Binding<String>?
    @Environment(\.appContainer) private var container
    @State private var localSearchQuery = ""
    @State private var viewModel: SearchViewModel?
    @State private var isSearchActive = false
    @FocusState private var searchFocused: Bool
    @State private var category: SearchCategory = .all
    @State private var downloadsOnly = false

    private var searchQuery: Binding<String> { externalSearchQuery ?? $localSearchQuery }
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
    private var trimmedQuery: String { searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var serverId: String { container?.serverState.activeServer?.id.uuidString ?? "" }
    private var isOnline: Bool { container?.serverState.isOnline != false }
    private var searchRunKey: String {
        "\(trimmedQuery)|\(serverId)|\(container?.serverState.isServerReachable != false)|\(downloadsOnly)|\(isOnline)|\(viewModel != nil)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearchActive { searchScope }
            if !searchFocused, !trimmedQuery.isEmpty { categoryPicker }

            Group {
                if trimmedQuery.isEmpty {
                    searchLanding
                } else if let vm = viewModel {
                    SearchResultsList(
                        viewModel: vm,
                        category: downloadsOnly ? .songs : category,
                        query: trimmedQuery,
                        showsSuggestions: searchFocused,
                        downloadsOnly: downloadsOnly,
                        onSuggestion: { suggestion in
                            searchQuery.wrappedValue = suggestion
                            searchFocused = false
                        },
                        onRetry: {
                            await vm.retryLocalIndexIfNeeded()
                            await runSearch()
                        }
                    )
                } else {
                    LoadingStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Focus animates the small header/scope chrome. Inserting an entire history List
            // into that same transaction also animates every row while the keyboard lays out.
            .transaction { $0.animation = nil }
        }
        .navigationTitle(String(localized: "Search", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .cassetteAccountProfileToolbar(isVisible: !isSearchActive)
        .searchable(text: searchQuery, isPresented: $isSearchActive,
            placement: searchPlacement,
            prompt: Text("Artists, Songs, Lyrics, and More"))
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { searchFocused = false }
        .onAppear {
            if viewModel == nil, let container {
                let store = SearchDownloadStore(modelContainer: container.modelContainer)
                viewModel = SearchViewModel(
                    libraryService: container.libraryService,
                    libraryIndex: container.libraryIndexService,
                    downloads: { [weak container] query in
                        guard let id = container?.serverState.activeServer?.id else { return [] }
                        return await store.matching(query, serverId: id)
                    }
                )
            }
            viewModel?.prepareLocalIndex()
            if #available(iOS 27.0, macOS 27.0, *), let query = SiriSearchRequestStore.consume() {
                searchQuery.wrappedValue = query
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteFocusSearch)) { _ in
            if !isSearchActive { isSearchActive = true }
            if !searchFocused { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteSearchInApp)) { note in
            guard let query = note.userInfo?["query"] as? String else { return }
            searchQuery.wrappedValue = query
            _ = SiriSearchRequestStore.consume()
            searchFocused = false
        }
        .task(id: container?.libraryIndexService.lastIndexedAt) {
            await viewModel?.refreshLocalResults(includeDownloads: false)
        }
        .task(id: container?.libraryIndexService.lastError?.id) {
            guard container?.libraryIndexService.lastError != nil, !trimmedQuery.isEmpty else { return }
            await runSearch()
        }
        .onChange(of: downloadsOnly) { _, _ in category = .all }
        .onChange(of: isSearchActive) { _, active in
            if !active, trimmedQuery.isEmpty { category = .all }
        }
        .task(id: searchRunKey) { await runSearch() }
        .miniPlayerBottomMargin()
        .cassetteContentWidth()
    }

    private func runSearch() async {
        await viewModel?.search(
            query: trimmedQuery,
            serverReachable: isOnline && container?.serverState.isServerReachable != false,
            downloadsOnly: downloadsOnly
        )
    }

    private var searchScope: some View {
        Picker(String(localized: "Search Scope", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), selection: $downloadsOnly) {
            if isOnline {
                Text(String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(false)
            } else {
                Text(String(localized: "Indexed Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(false)
            }
            Text(String(localized: "Downloads", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(downloadsOnly ? [.all, .songs] : SearchCategory.allCases) { item in
                    Button { category = item } label: { Text(item.title) }
                        .buttonStyle(.bordered)
                        .tint(category == item ? Color.accentColor : Color.secondary)
                        .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var searchLanding: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: CassetteSpacing.xl) {
                SearchHistoryListView(serverId: serverId, path: $path, embedsInScrollView: true)
                MacSearchBrowseCategories(path: $path)
            }
        }
        #else
        ZStack {
            SearchHistoryListView(serverId: serverId, path: $path)
                .opacity(isSearchActive ? 1 : 0)
                .allowsHitTesting(isSearchActive)
                .accessibilityHidden(!isSearchActive)
            ScrollView {
                SearchBrowseCategories { genre in
                    searchQuery.wrappedValue = genre
                    category = .songs
                    searchFocused = false
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .opacity(isSearchActive ? 0 : 1)
            .allowsHitTesting(!isSearchActive)
            .accessibilityHidden(isSearchActive)
        }
        #endif
    }
}

#if os(iOS)
private struct SearchBrowseCategories: View {
    private struct Category: Identifiable {
        let title: String
        let query: String
        let symbol: String
        let colors: [Color]
        var id: String { query }
    }

    @Environment(\.appContainer) private var container
    @State private var genreCovers: [String: String] = [:]
    let onSelect: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private let genres: [Category] = [
        Category(title: "Pop", query: "Pop", symbol: "sparkles", colors: [.pink, .purple]),
        Category(title: "Dance", query: "Dance", symbol: "figure.dance", colors: [.green, .teal]),
        Category(title: "Electronic", query: "Electronic", symbol: "waveform", colors: [.mint, .blue]),
        Category(title: "Hip-Hop/Rap", query: "Hip-Hop", symbol: "music.note", colors: [.blue, .indigo]),
        Category(title: "R&B", query: "R&B", symbol: "music.quarternote.3", colors: [.purple, .pink]),
        Category(title: "Rock", query: "Rock", symbol: "guitars.fill", colors: [.red, .orange]),
        Category(title: "Jazz", query: "Jazz", symbol: "pianokeys", colors: [.cyan, .blue]),
        Category(title: "Classical", query: "Classical", symbol: "pianokeys", colors: [.indigo, .purple]),
        Category(title: "Alternative", query: "Alternative", symbol: "bolt.fill", colors: [.orange, .pink]),
        Category(title: "Soundtrack", query: "Soundtrack", symbol: "film.fill", colors: [.red, .purple])
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(genres) { genre in
                Button { onSelect(genre.query) } label: {
                    SearchBrowseCategoryCard(
                        title: genre.title,
                        systemImage: genre.symbol,
                        colors: genre.colors,
                        coverArtId: genreCovers[genre.query]
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .task(id: "\(container?.serverState.activeServer?.id.uuidString ?? "")|\(container?.libraryIndexService.lastIndexedAt?.description ?? "")") {
            genreCovers = [:]
            // Let the tab's first frame and transition finish before starting artwork work.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let covers = await container?.libraryIndexService.browseCoverArtIDs(for: genres.map(\.query)) ?? [:]
            guard !Task.isCancelled else { return }
            genreCovers = covers
        }
    }
}

private struct SearchBrowseCategoryCard: View {
    let title: String
    let systemImage: String
    let colors: [Color]
    let coverArtId: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                if let coverArtId {
                    CoverArtView(id: coverArtId, size: 240, tier: .thumb)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay {
                            Rectangle()
                                .fill(colors[0])
                                .opacity(0.55)
                                .blendMode(.color)
                        }
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.48)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(LocalizedStringKey(title))
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(14)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
#endif
