// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music–style small Now Playing: edge-to-edge artwork, bottom fade, title + circular control.
struct NowPlayingSmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WidgetCoverArtView(image: entry.coverImage, cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.15),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)

                if let track = entry.track {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                } else {
                    Text("Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }

                HStack {
                    Spacer(minLength: 0)
                    WidgetPlayButton(isPlaying: entry.isPlaying, compact: true)
                        .environment(\.colorScheme, .dark)
                }
            }
            .padding(12)
        }
        .containerBackground(for: .widget) {
            Color.black
        }
    }
}
