// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Lyric line emphasis via opacity/scale only — no `.blur`, which frosted the bottom of the
/// lyrics viewport (right above the translate / scrubber chrome) into an unreadable band.
struct LyricsLineView: View {
    let value: String
    let index: Int
    let currentIndex: Int?
    let isSynced: Bool
    let isTappable: Bool
    let onTap: () -> Void

    private var distance: Int {
        guard let currentIndex else { return 0 }
        return abs(index - currentIndex)
    }

    private var opacity: Double {
        guard isSynced, currentIndex != nil else { return 1.0 }
        switch distance {
        case 0: return 1.0
        case 1: return 0.82
        case 2: return 0.62
        default: return 0.48
        }
    }

    private var scale: CGFloat {
        guard isSynced, currentIndex != nil else { return 1.0 }
        return distance == 0 ? 1.05 : 1.0
    }

    private var lineFont: Font {
        .system(.title, design: .rounded, weight: .bold)
    }

    var body: some View {
        Text(value)
            .font(lineFont)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white.opacity(opacity))
            // Soft shadow keeps white lyrics readable on bright / washed cover themes.
            .shadow(color: .black.opacity(distance == 0 ? 0.55 : 0.35), radius: distance == 0 ? 3 : 2, y: 1)
            .scaleEffect(scale, anchor: .leading)
            .animation(CassetteAnimation.lyricLine, value: currentIndex)
            .contentShape(Rectangle())
            .onTapGesture {
                if isTappable { onTap() }
            }
    }
}
