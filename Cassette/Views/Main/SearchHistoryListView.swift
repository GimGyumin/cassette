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
    @State private var rowsData: [SearchHistoryRowData] = []
    @State private var revision = 0
    @State private var showClearConfirm = false

    init(serverId: String, path: Binding<NavigationPath>, showsClearButton: Bool = true, embedsInScrollView: Bool = false) {
        self.serverId = serverId
        self._path = path
        self.showsClearButton = showsClearButton
        self.embedsInScrollView = embedsInScrollView
    }

    var body: some View {
        Group {
            if embedsInScrollView {
                embeddedHistory(rowsData: rowsData)
            } else if rowsData.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Search your library",
                    subtitle: "Find songs, albums, artists, and playlists from your server."
                )
            } else {
                List {
                    Section {
                        ForEach(rowsData) { rowData in
                            historyRowButton(rowData)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
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
        .task(id: "\(serverId):\(revision)") {
            guard let service = container?.searchHistoryService else { return }
            let snapshot = await service.recent(serverId: serverId)
            guard !Task.isCancelled else { return }
            if rowsData != snapshot { rowsData = snapshot }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchHistoryService.didChange)) { note in
            if note.object as? String == serverId { revision &+= 1 }
        }
    }

    @ViewBuilder
    private func embeddedHistory(rowsData: [SearchHistoryRowData]) -> some View {
        if rowsData.isEmpty {
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
            SearchHistoryEntryRow(data: rowData).equatable()
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
