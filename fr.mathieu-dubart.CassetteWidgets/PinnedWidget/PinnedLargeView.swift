// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music Pins large: up to six covers in a 3-column grid.
struct PinnedLargeView: View {
    let entry: PinnedEntry

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pins")
                        .font(.system(size: 15, weight: .semibold))
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(entry.items.prefix(6), id: \.id) { item in
                            PinnedTileView(
                                item: item,
                                image: entry.coverImages[item.coverArtFilename ?? ""],
                                coverSize: 92
                            )
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pins")
                .font(.system(size: 17, weight: .semibold))
            Text("Pin albums or playlists in Cassette")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
