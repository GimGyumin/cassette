// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum CassetteSystemSettings {
    /// Opens the system Settings page for Cassette (iOS Settings.app).
    /// On macOS the app already uses the native Settings window (Cassette → Settings…).
    @MainActor
    static func openAppSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        #endif
    }
}
