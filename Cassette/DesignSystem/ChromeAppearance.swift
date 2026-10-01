// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Shared controller that lets a detail page (album/playlist/artist) push its cover-derived
/// light/dark appearance up to the root chrome — tab bar and mini player — so their text /
/// glyphs flip to white or black to match the currently visible artwork page.
///
/// Detail pages write an override while visible and clear it on disappear; everything else
/// reads `overrideColorScheme ?? system colorScheme`.
@MainActor
@Observable
final class ChromeAppearance {
    /// Non-nil only while a themed detail page is frontmost and wants a forced scheme.
    private var owners: [(id: UUID, scheme: ColorScheme?)] = []
    var overrideColorScheme: ColorScheme? { owners.last?.scheme }

    func appear(id: UUID, scheme: ColorScheme?) {
        owners.removeAll { $0.id == id }
        owners.append((id, scheme))
    }

    func update(id: UUID, scheme: ColorScheme?) {
        guard let index = owners.firstIndex(where: { $0.id == id }) else { return }
        owners[index].scheme = scheme
    }

    func disappear(id: UUID) { owners.removeAll { $0.id == id } }
}

extension View {
    /// Pushes a themed detail page's `preferredColorScheme` into the shared
    /// `ChromeAppearance` while visible, restoring the previous override on disappear.
    func chromeAppearance(_ scheme: ColorScheme?) -> some View {
        modifier(ThemedChromeSchemeModifier(scheme: scheme))
    }
}

private struct ThemedChromeSchemeModifier: ViewModifier {
    let scheme: ColorScheme?
    @Environment(ChromeAppearance.self) private var chromeAppearance
    @State private var ownerID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { chromeAppearance.appear(id: ownerID, scheme: scheme) }
            .onChange(of: scheme) { _, newValue in
                // The cover color resolves asynchronously (initially .clear → nil scheme);
                // push the real light/dark as soon as it lands so mini player / tab chrome
                // re-render with the correct glyph ink.
                chromeAppearance.update(id: ownerID, scheme: newValue)
            }
            .onDisappear {
                chromeAppearance.disappear(id: ownerID)
            }
    }
}
