// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Primary action button — tinted-glass capsule with play icon. Used in album and playlist headers.
struct PlayButton: View {
    let action: () -> Void
    var label: String = "Play"
    var isDisabled: Bool = false
    var accentColor: Color = CassetteColors.accent
    /// Label/glyph color. Default white (`cassetteAccentText`) preserves existing callers; the hero passes the
    /// cover-derived tint (or B/W fallback) on a black/white capsule.
    var labelColor: Color = Color.cassetteAccentText

    var body: some View {
        Button {
            HapticFeedback.medium.trigger()
            action()
        } label: {
            Label(label, systemImage: "play.fill")
                .font(.cassetteCellTitle)
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CassetteSpacing.m)
                .background {
                    Capsule(style: .continuous)
                        .fill(accentColor.opacity(isDisabled ? 0.45 : 1))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

#Preview {
    VStack(spacing: CassetteSpacing.l) {
        PlayButton(action: {})
        PlayButton(action: {}, label: "Shuffle", isDisabled: true)
    }
    .padding()
}
