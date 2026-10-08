// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Apple Music–style search field. Keeps a single `TextField` in the tree so focusing
/// doesn’t tear down / rebuild the bar (Button ↔ TextField swap caused focus lag).
struct AppleMusicSearchBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var text: String
    @Binding var isActive: Bool
    var prompt: String = String(localized: "Artists, Songs, Lyrics, and More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    var onCancel: () -> Void = {}
    /// Bump to request keyboard focus (search tab reselect / external focus).
    var focusToken: Int = 0
    var onSubmit: () -> Void = {}

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: CassetteSpacing.s) {
            HStack(spacing: CassetteSpacing.s) {
                Button {
                    activateAndFocus()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title2.weight(.regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Search", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                TextField(prompt, text: $text)
                    .font(.title3)
                    .focused($fieldFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        fieldFocused = false
                        isActive = false
                        onSubmit()
                    }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } else {
                    Button {
                        activateAndFocus()
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title2.weight(.regular))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Voice Search", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }

            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .cassetteGlassCapsule()
            .simultaneousGesture(TapGesture().onEnded { activateAndFocus() })

            if isActive || !text.isEmpty {
                Button {
                    fieldFocused = false
                    text = ""
                    isActive = false
                    onCancel()
                } label: {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.regular))
                            .cassetteGlassButton(size: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : CassetteAnimation.chrome, value: isActive || !text.isEmpty)
        .onChange(of: fieldFocused) { _, focused in
            // Expand chrome only — never hide the nav bar from the parent on this
            // same focus change (that stole first-responder and forced a second tap).
            if focused, !isActive {
                isActive = true
            }
        }
        .onChange(of: focusToken) { _, _ in
            activateAndFocus()
        }
        .onChange(of: isActive) { _, active in
            if !active { fieldFocused = false }
        }
    }

    private func activateAndFocus() {
        if !isActive { isActive = true }
        fieldFocused = true
    }
}

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
