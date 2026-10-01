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
    @State private var showAccountSheet = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if isVisible {
            content
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAccountSheet = true
                        } label: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.body)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
                .sheet(isPresented: $showAccountSheet) {
                    AccountSheetView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(28)
                }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Places the account/profile button in the navigation bar trailing slot,
    /// aligned with an inline-large root title. Opens as a sheet (not a push).
    func cassetteAccountProfileToolbar(isVisible: Bool = true) -> some View {
        modifier(AccountProfileToolbarModifier(isVisible: isVisible))
    }

    /// Root tab title + trailing actions on one row (Library’s custom toolbar).
    func cassetteRootTabTitleAlignment() -> some View {
        #if os(iOS)
        toolbarTitleDisplayMode(.inlineLarge)
        #else
        self
        #endif
    }
}
