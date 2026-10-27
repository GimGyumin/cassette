// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog

/// Cross-platform album link used by shelves, grids and lists.
///
/// Album navigation deliberately does **not** use a zoom transition. The page is
/// pushed with the standard NavigationStack transition; only the page's own cover
/// expansion (where present) uses zoom. This keeps interactive pop tied to UIKit's
/// normal transition instead of a matched-source transition that can be invalidated
/// by a lazy/re-created card.
struct AlbumNavigationLink<Label: View>: View {
    let album: AlbumID3
    /// Kept for the label's existing matched-source modifiers. With the page zoom
    /// removed those modifiers are inert; the namespace is still passed so card APIs
    /// do not need to change.
    let namespace: Namespace.ID
    var destination: HomeDestination? = nil
    @ViewBuilder let label: (String, Namespace.ID) -> Label

    private var sourceID: String { album.id }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationLink(value: destination ?? .album(album)) { label(sourceID, namespace) }
            #else
            DetailNavigationLink(destination: destination ?? .album(album)) { label(sourceID, namespace) }
            #endif
        }
        #if os(iOS)
        .onAppear {
            Logger.ui.debug("[ALBUM-NAV] source appear album=\(album.id, privacy: .public) source=\(sourceID, privacy: .public) ns=\(String(describing: namespace), privacy: .public)")
        }
        .onDisappear {
            Logger.ui.debug("[ALBUM-NAV] source disappear album=\(album.id, privacy: .public) source=\(sourceID, privacy: .public) ns=\(String(describing: namespace), privacy: .public)")
        }
        #endif
    }
}
