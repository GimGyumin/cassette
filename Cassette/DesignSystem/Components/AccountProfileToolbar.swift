// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Trailing profile control that opens the Cassette Account sheet (iOS).
/// App preferences live in Cassette's in-app settings screen.
///
/// Uses `.inlineLarge` so the root tab title (Home / Discover / …) sits on the same
/// horizontal band as the account button — matching Apple Music’s Library chrome.
struct AccountProfileToolbarModifier: ViewModifier {
    var isVisible: Bool = true
    var opensSettings: Bool = false
    @State private var showAccountSheet = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbarTitleDisplayMode(.inlineLarge)
            .cassetteSoftTopScrollEdge()
            .toolbar {
                if isVisible {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAccountSheet = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.primary)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(opensSettings ? String(localized: "Settings", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }
            .sheet(isPresented: $showAccountSheet) {
                Group {
                    if opensSettings { NavigationStack { SettingsView() } }
                    else { AccountSheetView() }
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        #else
        content
        #endif
    }
}

/// Keep the navigation container and its safe area alive while removing only root chrome.
/// The same scroll state controls the title and the root's toolbar items, including their glass.
private struct RootHeaderScrollModifier: ViewModifier {
    @Binding var isScrolled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0
            } action: { _, scrolled in
                isScrolled = scrolled
            }
            .toolbar(removing: isScrolled ? .title : nil)
            .toolbarBackgroundVisibility(isScrolled ? .hidden : .automatic, for: .navigationBar)
        #else
        content
        #endif
    }
}

extension View {
    func cassetteScrollingRootHeader(isScrolled: Binding<Bool>) -> some View {
        modifier(RootHeaderScrollModifier(isScrolled: isScrolled))
    }

    /// Places the account/profile button in the navigation bar trailing slot,
    /// aligned with an inline-large root title. Opens as a sheet (not a push).
    func cassetteAccountProfileToolbar(isVisible: Bool = true, opensSettings: Bool = false) -> some View {
        modifier(AccountProfileToolbarModifier(isVisible: isVisible, opensSettings: opensSettings))
    }

    /// Root tab title + trailing actions on one row (Library’s custom toolbar).
    func cassetteRootTabTitleAlignment() -> some View {
        #if os(iOS)
        toolbarTitleDisplayMode(.inlineLarge)
            .cassetteSoftTopScrollEdge()
        #else
        self
        #endif
    }
}
