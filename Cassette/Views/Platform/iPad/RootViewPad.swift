// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI

/// Legacy iPad entry point. Regular-width iPad now uses `MainTabView` with
/// `.tabViewStyle(.sidebarAdaptable)` (floating top tab bar + system mini player).
/// Kept as a thin alias so older call sites keep compiling.
struct RootViewPad: View {
    var body: some View {
        MainTabView()
    }
}
#endif
