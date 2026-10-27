// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Song transitions and optional playback feedback.
struct PlaybackSettingsView: View {
    @Environment(\.appContainer) private var container
    @ObservedObject private var appleMusic = AppleMusicSettings.shared

    #if os(iOS)
    @State private var musicHapticsActive = false
    #endif

    private var crossfade: CrossfadeSettings? { container?.crossfadeSettings }
    private var gapless: GaplessSettings? { container?.gaplessSettings }

    var body: some View {
        Form {
            playbackSection
            LegacyPlaybackSessionSection()
            #if os(iOS)
            hapticsSection
            #endif
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Song Transitions"))
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
            SettingsSectionHeader("Song Transitions")
        } footer: {
            SettingsSectionFooter("Gapless playback removes silence between consecutive tracks. Crossfade fades out one track and fades in the next.")
        }
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
