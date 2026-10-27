// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

enum SettingsOnOffChoice: CaseIterable, SettingsChoiceItem {
    case on, off

    init(_ enabled: Bool) { self = enabled ? .on : .off }

    var choiceTitle: String {
        self == .on
            ? String(localized: "On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}

struct DolbyAtmosSettingsView: View {
    @Environment(\.appContainer) private var container
    @Bindable var settings: StreamingSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.preferDolbyAtmos },
                    set: {
                        settings.preferDolbyAtmos = $0
                        Task { await container?.playerService.playbackVariantSettingsDidChange() }
                    }
                )) {
                    Text("Prefer Dolby Atmos")
                }
            } footer: {
                SettingsSectionFooter("When enabled, plays a matching Dolby Atmos version from your server while keeping the original song title, artwork, and album information. If no reliable match is available, plays the original song. Changes apply to the next song.\n\nSpatial playback depends on the source file and connected audio device.")
            }
            Section {
                Toggle("Allow Dolby Atmos over Cellular", isOn: $settings.allowDolbyAtmosOverCellular)
                    .onChange(of: settings.allowDolbyAtmosOverCellular) { _, _ in
                        Task { await container?.playerService.playbackVariantSettingsDidChange() }
                    }
            } footer: {
                SettingsSectionFooter("When disabled, cellular playback uses the original song instead of a Dolby Atmos alternative. Dolby-only songs require Wi-Fi or a downloaded original. Changes apply to the next song.")
            }
        }
        .modifier(SettingsSubpageStyle())
        .navigationTitle("Dolby Atmos")
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
