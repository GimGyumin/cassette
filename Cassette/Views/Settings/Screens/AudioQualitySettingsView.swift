// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Streaming and download quality, grouped the way Apple Music groups it:
/// one card per network, one card for downloads.
///
/// Automatic derives the server route from quality/capabilities; the method picker can override it.
struct AudioQualitySettingsView: View {
    @Environment(\.appContainer) private var container
    @Bindable var settings: StreamingSettings
    @AppStorage("cassette.download.automaticAfterStreaming") private var automaticDownloadsEnabled = false
    @AppStorage("cassette.download.automaticOverCellular") private var automaticDownloadsOverCellular = false

    private static let qualityFooter: LocalizedStringKey =
        "Automatic prefers the original on a capable connection. Lossless plays the original file when available; Jellyfin transcoding and HLS use lossy audio."

    var body: some View {
        Form {
            streamingSection
            Section {
                Toggle(isOn: $settings.preferDolbyAtmos) {
                    SettingsRowTitle("Prefer Dolby Atmos")
                }
            } footer: {
                SettingsSectionFooter("Plays matching files from albums ending in (Dolby Atmos). Uses the original song when no reliable match is available. Changes apply to the next song.")
            }
            Section {
                SettingsNavigationRow("Server Playback Method", value: settings.jellyfinRoute.choiceTitle) {
                    ServerPlaybackMethodSelectionView(selection: $settings.jellyfinRoute)
                }
            }
            downloadsSection
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Audio Quality"))
        .onChange(of: settings.preferDolbyAtmos) {
            Task { await container?.playerService.playbackVariantSettingsDidChange() }
        }
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
                AudioQualitySelectionView(title: "Download Quality", selection: $settings.downloadFormat, isStreaming: false)
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
    var isStreaming = true

    var body: some View {
        SettingsChoiceList(
            navigationTitle: title,
            footer: "Lossless uses much more data. Availability depends on the original files on your server.",
            items: CacheFormat.selectableCases,
            selection: $selection,
            subtitle: { format in
                if isStreaming, format == .matchStream {
                    return String(localized: "Adapts to your connection and prefers original quality", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                }
                return format.subtitle
            }
        )
    }
}
