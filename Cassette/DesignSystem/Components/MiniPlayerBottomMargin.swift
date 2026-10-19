// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// The macOS overlay needs a content margin. iOS TabView accessories and safeAreaInset
/// already reserve their own space, including during minimization and Dynamic Type changes.
private struct MiniPlayerBottomMargin: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .contentMargins(.bottom, CassetteMacOSLayout.playerBarReservedHeight, for: .scrollContent)
        #else
        content
        #endif
    }
}

extension View {
    /// Adds bottom scroll margin matching the mini player accessory (iOS) or BottomPlayerBar (macOS).
    func miniPlayerBottomMargin() -> some View {
        modifier(MiniPlayerBottomMargin())
    }
}
