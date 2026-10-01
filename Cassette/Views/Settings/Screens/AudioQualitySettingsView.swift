// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Streaming and download quality, grouped the way Apple Music groups it:
/// one card per network, one card for downloads.
///
/// There is no server playback-method row: `MediaResolver` always asks for the automatic Jellyfin
/// decision, so Direct Play vs a server-side transcode follows from the quality chosen here, the
/// current network and the source itself (`PlaybackDecisionPolicy`).
struct AudioQualitySettingsView: View {
    @Bindable var settings: StreamingSettings
    @AppStorage("cassette.download.automaticAfterStreaming") private var automaticDownloadsEnabled = false
    @AppStorage("cassette.download.automaticOverCellular") private var automaticDownloadsOverCellular = false

    private static let qualityFooter: LocalizedStringKey =
        "Lossless uses much more data. Availability depends on the original files on your server. On cellular, Automatic measures the connection and lowers the quality when the network cannot keep up."

    var body: some View {
        Form {
            streamingSection
            downloadsSection
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Audio Quality"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var streamingSection: some View {
        Section {
            SettingsNavigationRow("Wi-Fi", value: settings.wifiFormat.title) {
                AudioQualitySelectionView(title: "Wi-Fi", selection: $settings.wifiFormat)
            }

            SettingsNavigationRow("Cellular", value: settings.cellularFormat.title) {
                AudioQualitySelectionView(title: "Cellular", selection: $settings.cellularFormat)
            }
        } header: {
            SettingsSectionHeader("Streaming")
        } footer: {
            SettingsSectionFooter(Self.qualityFooter)
        }
    }

    private var downloadsSection: some View {
        Section {
            SettingsNavigationRow("Download Quality", value: settings.downloadFormat.title) {
                AudioQualitySelectionView(title: "Download Quality", selection: $settings.downloadFormat)
            }

            Toggle(isOn: $automaticDownloadsEnabled) {
                SettingsRowTitle("Automatic Downloads")
            }

            Toggle(isOn: $automaticDownloadsOverCellular) {
                SettingsRowTitle("Automatic Downloads over Cellular")
            }
            .disabled(!automaticDownloadsEnabled)
        } header: {
            SettingsSectionHeader("Downloads")
        } footer: {
            SettingsSectionFooter("When disabled, automatic downloads wait for Wi-Fi. This controls permanent downloads only — streaming cache and prefetching are controlled by the Cache settings.")
        }
    }
}

/// Apple Music-style quality list: title and subtitle rows with a trailing
/// blue checkmark for the current selection.
struct AudioQualitySelectionView: View {
    let title: LocalizedStringKey
    @Binding var selection: CacheFormat

    var body: some View {
        SettingsChoiceList(
            navigationTitle: title,
            footer: "Lossless uses much more data. Availability depends on the original files on your server.",
            items: CacheFormat.selectableCases,
            selection: $selection
        )
    }
}
