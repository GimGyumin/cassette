// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

/// Apple Music–style medium Now Playing: blurred art backdrop, lifted square cover, clean type, round control.
struct NowPlayingMediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 14) {
            WidgetCoverArtView(image: entry.coverImage, cornerRadius: 12)
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            VStack(alignment: .leading, spacing: 3) {
                if let track = entry.track {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                } else {
                    Text("Not Playing")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Open Cassette to play")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    WidgetPlayButton(isPlaying: entry.isPlaying)
                        .environment(\.colorScheme, .dark)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .containerBackground(for: .widget) {
            WidgetReadableBackground(dominantColor: entry.dominantColor, image: entry.coverImage)
        }
    }
}
