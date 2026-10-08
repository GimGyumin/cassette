import SwiftUI
import SwiftSonic

/// All changing search state stays below SearchView's navigation destination shell.
struct SearchTabContent: View {
    @Binding var path: NavigationPath
    var externalSearchQuery: Binding<String>?
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localSearchQuery = ""
    @State private var viewModel: SearchViewModel?
    @State private var isSearchActive = false
    @State private var searchFocusToken = 0
    @State private var category: SearchCategory = .all
    @State private var downloadsOnly = false
    @State private var showAccountSheet = false

    private var searchQuery: Binding<String> { externalSearchQuery ?? $localSearchQuery }
    private var trimmedQuery: String { searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var serverId: String { container?.serverState.activeServer?.id.uuidString ?? "" }
    private var isOnline: Bool { container?.serverState.isOnline != false }
    private var searchRunKey: String {
        "\(trimmedQuery)|\(serverId)|\(container?.serverState.isServerReachable != false)|\(downloadsOnly)|\(isOnline)|\(viewModel != nil)"
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if !isSearchActive {
                HStack(alignment: .center) {
                    Text("Search")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Button {
                        showAccountSheet = true
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary)
                            .cassetteGlassButton(size: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif

            AppleMusicSearchBar(
                text: searchQuery, isActive: $isSearchActive,
                prompt: String(localized: "Artists, Songs, Lyrics, and More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                onCancel: { category = .all }, focusToken: searchFocusToken
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            if isSearchActive {
                searchScope
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !isSearchActive, !trimmedQuery.isEmpty { categoryPicker }

            Group {
                if trimmedQuery.isEmpty {
                    searchLanding
                } else if let vm = viewModel {
                    SearchResultsList(
                        viewModel: vm,
                        category: downloadsOnly ? .songs : category,
                        query: trimmedQuery,
                        showsSuggestions: isSearchActive,
                        downloadsOnly: downloadsOnly,
                        onSuggestion: { suggestion in
                            searchQuery.wrappedValue = suggestion
                            isSearchActive = false
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
        .animation(reduceMotion ? nil : CassetteAnimation.chrome, value: isSearchActive)
        #if os(iOS)
        // Keep this chrome stable during focus changes to preserve first responder.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(String(localized: "Search", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #endif
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
            searchFocusToken += 1
            isSearchActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteSearchInApp)) { note in
            guard let query = note.userInfo?["query"] as? String else { return }
            searchQuery.wrappedValue = query
            _ = SiriSearchRequestStore.consume()
            isSearchActive = false
        }
        .task(id: container?.libraryIndexService.lastIndexedAt) {
            await viewModel?.refreshLocalResults(includeDownloads: false)
        }
        .task(id: container?.libraryIndexService.lastError?.id) {
            guard container?.libraryIndexService.lastError != nil, !trimmedQuery.isEmpty else { return }
            await runSearch()
        }
        .onChange(of: downloadsOnly) { _, _ in category = .all }
        .task(id: searchRunKey) { await runSearch() }
        #if os(iOS)
        .sheet(isPresented: $showAccountSheet) {
            AccountSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
        #endif
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(downloadsOnly ? [.all, .songs] : SearchCategory.allCases) { item in
                    Button { category = item } label: {
                        Text(item.title)
                            .font(.body.weight(category == item ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(category == item ? Color.white : Color.primary)
                            .cassetteGlassCapsule(
                                tint: category == item ? Color.cassetteAccent.opacity(0.78) : nil
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
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
        if isSearchActive {
            SearchHistoryListView(serverId: serverId, path: $path)
        } else {
            ScrollView {
                SearchBrowseCategories { genre in
                    searchQuery.wrappedValue = genre
                    category = .songs
                    isSearchActive = false
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
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
        Category(title: "Jazz", query: "Jazz", symbol: "saxophone", colors: [.cyan, .blue]),
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
                        coverArtId: container?.libraryIndexService.browseCoverArtId(for: genre.query)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
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
                    CoverArtView(id: coverArtId, size: 480)
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
