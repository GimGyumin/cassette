// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music Pins medium: four equal cover tiles on a system material background.
struct PinnedMediumView: View {
    let entry: PinnedEntry

    var body: some View {
        Group {
            if entry.items.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(entry.items.prefix(4), id: \.id) { item in
                        PinnedTileView(
                            item: item,
                            image: entry.coverImages[item.coverArtFilename ?? ""],
                            coverSize: 72
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                .font(.system(size: 15, weight: .semibold))
            Text("Pin albums or playlists in Cassette")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
