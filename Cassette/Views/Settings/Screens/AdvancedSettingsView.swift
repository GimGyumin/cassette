// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Troubleshooting and onboarding. Kept out of the main settings list, and
/// only the actions that really destroy data are shown in red.
struct AdvancedSettingsView: View {
    @Environment(\.appContainer) private var container
    @State private var isClearingCache = false
    @State private var showClearCacheConfirm = false
    @State private var showResetSignInConfirm = false

    var body: some View {
        Form {
            Section {
                SettingsActionRow("Clear Cache", isDestructive: true, isBusy: isClearingCache) {
                    showClearCacheConfirm = true
                }
            } header: {
                SettingsSectionHeader("Troubleshooting")
            } footer: {
                SettingsSectionFooter("Clears playback cache, artwork memory, descriptions, and translations. Downloads and server sign-ins are kept.")
            }

            Section {
                OnboardingReplayButton()

                SettingsActionRow("Reset Sign-In Data", isDestructive: true) {
                    showResetSignInConfirm = true
                }
            } header: {
                SettingsSectionHeader("Onboarding")
            } footer: {
                SettingsSectionFooter("Resetting sign-in deletes saved servers and passwords, then starts onboarding again.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Advanced"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Clear all cached data?",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads and server logins are kept.")
        }
        .confirmationDialog(
            "Reset sign-in data?",
            isPresented: $showResetSignInConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Sign-In Data", role: .destructive) {
                Task { await container?.replayOnboarding() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved servers and passwords are deleted from this device.")
        }
    }

    private func clearCache() async {
        guard let container else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        await container.resetAllCachedData()
    }
}
