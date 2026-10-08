// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData

/// Value-type snapshot of a SearchHistoryEntry. Capturing only the fields the row
/// reads breaks the @Model observation dependency: the row body reads no @Observable
/// properties, so SwiftData merge events that re-fire coverArtId/serverId setters
/// on existing entries no longer reach row bodies.
///
/// Identifiable via PersistentIdentifier so ForEach can maintain stable row identity
/// across background snapshots without holding a @Model reference in the view tree.
nonisolated struct SearchHistoryRowData: Identifiable, Equatable, Sendable {
    let id: PersistentIdentifier
    let coverArtId: String?
    let itemId: String
    let itemType: String
    let displayName: String

    init(entry: SearchHistoryEntry) {
        self.id = entry.persistentModelID
        self.coverArtId = entry.coverArtId
        self.itemId = entry.itemId
        self.itemType = entry.itemType
        self.displayName = entry.displayName
    }
}

/// Row view for a single search history entry.
///
/// Equatable conformance is synthesized from SearchHistoryRowData. When
/// SearchHistoryListView.body re-runs due to @Query re-evaluation and produces
/// the same DTO values (no actual data change), SwiftUI's diffing skips calling
/// this body — eliminating the O(N × notifications) render storm from SwiftData
/// merge events that touched unchanged property values.
struct SearchHistoryEntryRow: View, Equatable {
    let data: SearchHistoryRowData

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtView(id: data.coverArtId ?? data.itemId, size: 88)
                .frame(width: 44, height: 44)
                .clipShape(
                    data.itemType == "artist"
                        ? AnyShape(Circle())
                        : AnyShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.standard))
                )
            Text(data.displayName)
                .font(.cassetteCellTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, CassetteSpacing.s)
        .padding(.horizontal, CassetteSpacing.m)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
