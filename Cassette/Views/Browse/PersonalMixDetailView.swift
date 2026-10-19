// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Compatibility entry point; all collections render the standard playlist screen.
struct PersonalMixDetailView: View {
    let kind: PersonalMixKind
    var body: some View { PlaylistDetailView(generatedSource: .personalMix(kind)) }
}
