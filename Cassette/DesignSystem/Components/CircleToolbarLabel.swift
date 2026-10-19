// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A toolbar owns its control background, hit target and pressed feedback.
struct CircleToolbarLabel: View {
    let systemName: String
    var filled: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(filled ? Color.cassetteAccent : Color.primary)
    }
}
