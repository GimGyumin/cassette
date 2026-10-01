// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// When `false`, the view must not register `.navigationDestination(for: HomeDestination.self)`
/// because a parent `NavigationStack` already owns that type (avoids NavigationRequestObserver spam).
private struct RegistersHomeDestinationsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var registersHomeDestinations: Bool {
        get { self[RegistersHomeDestinationsKey.self] }
        set { self[RegistersHomeDestinationsKey.self] = newValue }
    }
}
