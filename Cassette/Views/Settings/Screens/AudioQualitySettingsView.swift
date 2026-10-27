// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct AudioQualitySettingsView: View {
    @Bindable var settings: StreamingSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.losslessAudioEnabled) {
                    SettingsRowTitle("Lossless Audio")
                }
            } footer: {
                VStack(alignment: .leading, spacing: CassetteSpacing.l) {
                    SettingsSectionFooter("Lossless preserves all the detail in the original audio. Streaming and downloading lossless files uses more data and storage.")
                    NavigationLink("About Lossless Audio") { LosslessAudioInformationView() }
                        .font(.cassetteFootnote)
                        .textCase(nil)
                }
            }
            Section {
                SettingsNavigationRow("Wi-Fi Streaming", value: settings.formatForCurrentNetwork(isLimited: false).title) {
                    AudioQualitySelectionView(title: "Wi-Fi Streaming", selection: $settings.wifiFormat,
                                              losslessEnabled: settings.losslessAudioEnabled)
                }
                SettingsNavigationRow("Cellular Streaming", value: settings.formatForCurrentNetwork(isLimited: true).title) {
                    AudioQualitySelectionView(title: "Cellular Streaming", selection: $settings.cellularFormat,
                                              losslessEnabled: settings.losslessAudioEnabled)
                }
            } footer: {
                SettingsSectionFooter("Changes apply to new streams and downloads. Previously downloaded and cached music keeps its existing quality. Turning lossless back on restores your saved quality choices.")
            }
            Section {
                SettingsNavigationRow("Server Playback Method", value: settings.jellyfinRoute.choiceTitle) {
                    ServerPlaybackMethodSelectionView(selection: $settings.jellyfinRoute)
                }
            } footer: {
                SettingsSectionFooter("Automatic follows the selected audio quality. A manual original-file method and spatial audio may use the original source regardless of the lossless switch.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Audio Quality"))
    }
}

struct DownloadQualitySettingsView: View {
    @Bindable var settings: StreamingSettings

    var body: some View {
        AudioQualitySelectionView(title: "Downloads", selection: $settings.downloadFormat,
                                  isStreaming: false, losslessEnabled: settings.losslessAudioEnabled)
    }
}

/// Retain Cassette's real codec choices; never promise a sample-rate conversion the server cannot do.
struct AudioQualitySelectionView: View {
    let title: LocalizedStringKey
    @Binding var selection: CacheFormat
    var isStreaming = true
    var losslessEnabled = true

    private var items: [CacheFormat] {
        losslessEnabled ? [.matchStream, .aac256, .flacOriginal, .aac128, .opus_128] : [.aac256, .aac128, .opus_128]
    }

    var body: some View {
        SettingsChoiceList(
            navigationTitle: title,
            footer: isStreaming
                ? "Lossless streaming uses more data. The original file determines the format, bit depth, and sample rate, including high-resolution audio. Availability depends on your server, connection, and audio device."
                : "Lossless files use more storage on your device. Downloads preserve the original file's resolution when available. Previously downloaded songs keep their existing quality.",
            items: items,
            selection: Binding(
                get: { StreamingSettings.effectiveFormat(selection, losslessEnabled: losslessEnabled) },
                set: { selection = $0 }
            ),
            subtitle: { format in
                if format == .matchStream {
                    return isStreaming
                        ? String(localized: "Adapts to your connection and prefers original quality", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                        : String(localized: "Original file without conversion", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                }
                return format.subtitle
            }
        )
    }
}

private struct LosslessAudioInformationView: View {
    var body: some View {
        Form {
            Section {
                Text("Lossless preserves all the detail in the original audio. Streaming and downloading lossless files uses more data and storage.")
            }
            Section {
                Text("Cassette plays the original file from your server. Lossless and high-resolution availability depend on that file; choosing Lossless does not turn a lossy recording into lossless audio.")
            }
            Section {
                Text("The connected audio device can limit the output quality. Bluetooth playback may compress the audio even when the source file is lossless.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("About Lossless Audio"))
    }
}
