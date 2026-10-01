// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension ShareExpiration: SettingsChoiceItem {
    var choiceTitle: String { title }
}

extension ShareDescriptionMode: SettingsChoiceItem {
    var choiceTitle: String { title }
}

/// Share link options. Server implementation details are deliberately not
/// surfaced: users only see what a shared link does.
struct SharingSettingsView: View {
    @Bindable private var settings = ShareSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.allowDownloads) {
                    SettingsRowTitle("Allow Downloads")
                }

                Toggle(isOn: $settings.shareOriginalFormat) {
                    SettingsRowTitle("Share in Original Quality")
                }

                SettingsNavigationRow("Link Expiration", value: settings.expiration.title) {
                    SettingsChoiceList(
                        navigationTitle: "Link Expiration",
                        items: ShareExpiration.allCases,
                        selection: $settings.expiration
                    )
                }

                SettingsNavigationRow("Share Description", value: settings.descriptionMode.title) {
                    SettingsChoiceList(
                        navigationTitle: "Share Description",
                        items: ShareDescriptionMode.allCases,
                        selection: $settings.descriptionMode
                    )
                }
            } header: {
                SettingsSectionHeader("Share Link")
            } footer: {
                SettingsSectionFooter("Used whenever you share a track, album, or playlist.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Sharing"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
