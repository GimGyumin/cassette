// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Three dots that fill left-to-right in proportion to wait progress (0...1)
/// until the next lyric line.
struct LyricInstrumentalDotsView: View {
    let progress: Double
    var isActive: Bool = true

    private var clamped: Double { min(1, max(0, progress)) }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                ZStack {
                    Circle()
                        .fill(.white.opacity(isActive ? 0.45 : 0.3))
                    Circle()
                        .fill(.white)
                        .opacity(fillAmount(for: index))
                        .scaleEffect(0.92 + 0.08 * fillAmount(for: index))
                }
                .frame(width: 11, height: 11)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.linear(duration: 0.2), value: clamped)
        .accessibilityLabel(String(localized: "Instrumental", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }

    /// Continuous 0...1 fill for each dot so the trio drains remaining time smoothly.
    private func fillAmount(for index: Int) -> Double {
        guard isActive else { return 0 }
        let segment = 1.0 / 3.0
        let local = (clamped - Double(index) * segment) / segment
        return min(1, max(0, local))
    }
}
