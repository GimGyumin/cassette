// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// AMLL's three-dot performance, sampled from media time so pause/seek are exact.
struct LyricInstrumentalDotsView: View {
    let progress: Double
    var isActive = true
    var elapsedMs: Double = 0
    var durationMs: Double = 0
    var isIntro = false
    var allowsMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let performance = AMLLInterlude.sample(elapsedMs: elapsedMs, durationMs: durationMs,
            intro: isIntro, motion: !reduceMotion && allowsMotion)
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(.white)
                    .opacity(performance.dots[index])
                    .frame(width: 11, height: 11)
            }
        }
        .scaleEffect(performance.scale)
        .opacity(isActive ? performance.opacity : 0)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityLabel(String(localized: "Instrumental", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue("\(Int((min(1, max(0, progress)) * 100).rounded())) percent")
    }
}
