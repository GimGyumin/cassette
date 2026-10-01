// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog

struct SearchHistoryListView: View {
    let serverId: String
    @Binding var path: NavigationPath
    var showsClearButton: Bool = true
    /// When true (macOS Search landing), render history rows inside the parent ScrollView instead of a nested List.
    var embedsInScrollView: Bool = false

    @Environment(\.appContainer) private var container
    @Query private var historyEntries: [SearchHistoryEntry]
    @State private var showClearConfirm = false

    init(serverId: String, path: Binding<NavigationPath>, showsClearButton: Bool = true, embedsInScrollView: Bool = false) {
        self.serverId = serverId
        self._path = path
        self.showsClearButton = showsClearButton
        self.embedsInScrollView = embedsInScrollView
        var descriptor = FetchDescriptor<SearchHistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        _historyEntries = Query(descriptor)
    }

    private var serverHistory: [SearchHistoryEntry] {
        historyEntries.filter { $0.serverId == serverId }
    }

    var body: some View {
        let history = serverHistory
        let rowsData = history.map { SearchHistoryRowData(entry: $0) }
        if embedsInScrollView {
            embeddedHistory(history: history, rowsData: rowsData)
        } else if history.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Search your library",
                subtitle: "Find songs, albums, artists, and playlists from your server."
            )
        } else {
            List {
                Section {
                    LazyVStack(spacing: 0) {
                        ForEach(rowsData) { rowData in
                            historyRowButton(rowData)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    historyHeader
                }
            }
            .listStyle(.plain)
            .cassetteDestructiveAlert(
                "Clear search history?",
                isPresented: $showClearConfirm,
                message: "This will remove all your recent searches. This action cannot be undone.",
                destructiveButtonTitle: String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            ) {
                Task { await container?.searchHistoryService.clear(serverId: serverId) }
            }
        }
    }

    @ViewBuilder
    private func embeddedHistory(history: [SearchHistoryEntry], rowsData: [SearchHistoryRowData]) -> some View {
        if history.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "Search your library",
                subtitle: "Find songs, albums, artists, and playlists from your server."
            )
            .frame(maxWidth: .infinity)
            .padding(.top, CassetteSpacing.l)
        } else {
            VStack(alignment: .leading, spacing: CassetteSpacing.s) {
                historyHeader
                    .padding(.horizontal, CassetteSpacing.l)
                LazyVStack(spacing: 0) {
                    ForEach(rowsData) { rowData in
                        historyRowButton(rowData)
                    }
                }
            }
            .cassetteDestructiveAlert(
                "Clear search history?",
                isPresented: $showClearConfirm,
                message: "This will remove all your recent searches. This action cannot be undone.",
                destructiveButtonTitle: String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            ) {
                Task { await container?.searchHistoryService.clear(serverId: serverId) }
            }
        }
    }

    private var historyHeader: some View {
        HStack {
            Text(String(localized: "Recently Searched", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteSectionTitle)
                .foregroundStyle(.primary)
            Spacer()
            if showsClearButton {
                Button("Clear") {
                    showClearConfirm = true
                }
                .font(.cassetteBody)
                .foregroundStyle(Color.cassetteAccent)
            }
        }
        .textCase(nil)
    }

    private func historyRowButton(_ rowData: SearchHistoryRowData) -> some View {
        Button {
            let target = SearchHistoryNavTarget(
                itemId: rowData.itemId,
                itemType: rowData.itemType,
                displayName: rowData.displayName,
                coverArtId: rowData.coverArtId
            )
            Task {
                await container?.searchHistoryService.record(
                    itemId: rowData.itemId, itemType: rowData.itemType,
                    displayName: rowData.displayName, coverArtId: rowData.coverArtId,
                    serverId: serverId
                )
            }
            path.append(target)
        } label: {
            SearchHistoryEntryRow(data: rowData)
        }
        .buttonStyle(.plain)
        .modifier(SearchHistoryLongPressMenu(rowData: rowData))
    }
}

private struct SearchHistoryLongPressMenu: ViewModifier {
    let rowData: SearchHistoryRowData

    func body(content: Content) -> some View {
        switch rowData.itemType {
        case "album":
            content.albumLongPressMenu(
                id: rowData.itemId,
                name: rowData.displayName,
                coverArtId: rowData.coverArtId
            )
        case "playlist":
            content.playlistLongPressMenu(
                id: rowData.itemId,
                name: rowData.displayName,
                coverArtId: rowData.coverArtId
            )
        default:
            content
        }
    }
}

