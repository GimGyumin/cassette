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
    @State private var searchFocusToken = 0
    @State private var category: SearchCategory = .all
    @State private var downloadsOnly = false

    private var searchQuery: Binding<String> { externalSearchQuery ?? $localSearchQuery }
    private var trimmedQuery: String { searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var serverId: String { container?.serverState.activeServer?.id.uuidString ?? "" }
    private var isOnline: Bool { container?.serverState.isOnline != false }
    private var searchRunKey: String {
        "\(trimmedQuery)|\(serverId)|\(container?.serverState.isServerReachable != false)|\(downloadsOnly)|\(isOnline)|\(viewModel != nil)"
    }

    var body: some View {
        VStack(spacing: 0) {
            AppleMusicSearchBar(
                text: searchQuery, isActive: $isSearchActive,
                prompt: String(localized: "Search", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                onCancel: { category = .all }, focusToken: searchFocusToken
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if isSearchActive { searchScope }
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
                        onRetry: { await runSearch() }
                    )
                } else {
                    LoadingStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                        return store.matching(query, serverId: id)
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
        .onChange(of: container?.libraryIndexService.lastIndexedAt) { _, _ in
            viewModel?.refreshLocalResults(includeDownloads: false)
        }
        .onChange(of: downloadsOnly) { _, _ in category = .all }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(downloadsOnly ? [.all, .songs] : SearchCategory.allCases) { item in
                    Button { category = item } label: {
                        Text(item.title)
                            .font(.body.weight(category == item ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(category == item ? Color.white : Color.primary)
                            .background(category == item ? Color.cassetteAccent : .clear, in: Capsule())
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
        SearchHistoryListView(serverId: serverId, path: $path)
        #endif
    }
}
