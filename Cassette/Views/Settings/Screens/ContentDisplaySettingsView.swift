// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Catalog enrichment and Now Playing visuals. Implementation details
/// (Spotify credentials, cache machinery) are intentionally absent here.
struct ContentDisplaySettingsView: View {
    @ObservedObject private var appleMusic = AppleMusicSettings.shared
    @AppStorage("cassette.visuals.animatedArtwork") private var animatedArtwork = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $appleMusic.enrichMetadata) {
                    SettingsRowTitle("Enrich Album & Artist Info")
                }
            } header: {
                SettingsSectionHeader("Content")
            } footer: {
                SettingsSectionFooter("Fills missing album and artist descriptions from external sources.")
            }

            Section {
                Toggle(isOn: $animatedArtwork) {
                    SettingsRowTitle("Animated Background")
                }
            } header: {
                SettingsSectionHeader("Now Playing")
            } footer: {
                SettingsSectionFooter("The background moves with the music while Now Playing is visible.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Content & Display"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
