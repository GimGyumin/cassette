// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Reserves bottom scroll-content space for the floating mini player / BottomPlayerBar.
private struct MiniPlayerBottomMargin: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .contentMargins(.bottom, CassetteMacOSLayout.playerBarReservedHeight, for: .scrollContent)
        #else
        content
            .contentMargins(.bottom, CassetteSpacing.miniPlayerBottomMargin, for: .scrollContent)
        #endif
    }
}

extension View {
    /// Adds bottom scroll margin matching the mini player accessory (iOS) or BottomPlayerBar (macOS).
    func miniPlayerBottomMargin() -> some View {
        modifier(MiniPlayerBottomMargin())
    }
}
