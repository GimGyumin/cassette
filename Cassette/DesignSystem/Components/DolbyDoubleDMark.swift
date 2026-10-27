// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Monochrome double-D silhouette, matching the compact audio-format mark in
/// the supplied references. Vector geometry stays crisp at metadata/pill sizes.
struct DolbyDoubleDMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width * 0.44
        for mirrored in [false, true] {
            let edge = mirrored ? rect.maxX : rect.minX
            let direction: CGFloat = mirrored ? -1 : 1
            path.move(to: CGPoint(x: edge, y: rect.minY))
            path.addCurve(to: CGPoint(x: edge + direction * width, y: rect.midY),
                          control1: CGPoint(x: edge + direction * width * 0.65, y: rect.minY),
                          control2: CGPoint(x: edge + direction * width, y: rect.minY + rect.height * 0.22))
            path.addCurve(to: CGPoint(x: edge, y: rect.maxY),
                          control1: CGPoint(x: edge + direction * width, y: rect.maxY - rect.height * 0.22),
                          control2: CGPoint(x: edge + direction * width * 0.65, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Non-Dolby multichannel audio must retain a generic speaker symbol.
struct AudioFormatSymbol: View {
    let quality: AudioQualityKind
    let height: CGFloat

    var body: some View {
        Group {
            switch quality {
            case .dolbyAtmos, .dolby:
                DolbyDoubleDMark().fill(.foreground)
                    .frame(width: height * 1.45, height: height)
            default:
                Image(systemName: "speaker.wave.3.fill")
                    .resizable().scaledToFit()
                    .frame(width: height * 1.45, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}
