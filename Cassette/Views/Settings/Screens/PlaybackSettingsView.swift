// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Playback preferences, grouped the way Apple Music groups them: one card of
/// plain rows plus a single short footer — never a paragraph per setting.
struct PlaybackSettingsView: View {
    @Environment(\.appContainer) private var container
    @AppStorage("cassette.history.enabled") private var listeningHistoryEnabled = true
    @ObservedObject private var appleMusic = AppleMusicSettings.shared

    #if os(iOS)
    @State private var musicHapticsActive = false
    #endif

    private var replayGain: ReplayGainSettings? { container?.replayGainSettings }
    private var crossfade: CrossfadeSettings? { container?.crossfadeSettings }
    private var gapless: GaplessSettings? { container?.gaplessSettings }

    var body: some View {
        Form {
            playbackSection
            #if os(iOS)
            hapticsSection
            #endif
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Playback"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .task {
            MusicHapticsController.shared.refresh()
            musicHapticsActive = MusicHapticsController.shared.isSystemActive
            // Poll lightly — system Music Haptics may change while this screen is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                MusicHapticsController.shared.refresh()
                musicHapticsActive = MusicHapticsController.shared.isSystemActive
            }
        }
        #endif
    }

    // MARK: - 재생

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $listeningHistoryEnabled) {
                SettingsRowTitle("Listening History")
            }

            Toggle(isOn: Binding(
                get: { replayGain?.enabled ?? false },
                set: { newValue in
                    replayGain?.enabled = newValue
                    Task { await container?.playerService.replayGainSettingsDidChange() }
                }
            )) {
                SettingsRowTitle("Volume Leveling")
            }

            if replayGain?.enabled == true {
                SettingsNavigationRow("Volume Leveling Options", value: replayGainModeValue) {
                    ReplayGainDetailSettingsView()
                }
            }

            Toggle(isOn: Binding(
                get: { gapless?.isEnabled ?? GaplessSettings.defaultEnabled },
                set: { newValue in
                    gapless?.isEnabled = newValue
                    Task { await container?.playerService.gaplessSettingsDidChange() }
                }
            )) {
                SettingsRowTitle("Gapless Playback")
            }

            SettingsNavigationRow("Crossfade", value: crossfadeValue) {
                CrossfadeSettingsView()
            }
        } header: {
            SettingsSectionHeader("Playback")
        } footer: {
            SettingsSectionFooter("Removes the silence between consecutive tracks. Volume leveling evens out loudness differences between tracks.")
        }
    }

    private var replayGainModeValue: String {
        (replayGain?.mode ?? .track) == .track
            ? String(localized: "Track", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private var crossfadeValue: String {
        let duration = crossfade?.duration ?? 0
        guard duration > 0 else {
            return String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(format: String(localized: "%.1f s", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), duration)
    }

    // MARK: - 햅틱

    #if os(iOS)
    private var hapticsSection: some View {
        Section {
            Toggle(isOn: $appleMusic.musicHapticsEnabled) {
                SettingsRowTitle("Music Haptics")
            }

            SettingsValueRow(
                "System Music Haptics",
                value: musicHapticsActive
                    ? String(localized: "On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    : String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )

            SettingsActionRow("Accessibility Settings") {
                MusicHapticsController.shared.openSystemSettings()
            }
        } header: {
            SettingsSectionHeader("Haptics")
        } footer: {
            SettingsSectionFooter("Music Haptics needs to be enabled in Accessibility Settings as well.")
        }
    }
    #endif
}
