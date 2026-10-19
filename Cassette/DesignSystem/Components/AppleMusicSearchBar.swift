// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    /// Matches the Music app's library search drawer: hidden at rest, revealed by
    /// pulling the collection down, and collapsed again as content scrolls up.
    @ViewBuilder
    func cassetteLibrarySearch(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(
            text: text,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text(prompt)
        )
        #else
        searchable(text: text, prompt: Text(prompt))
        #endif
    }
}
