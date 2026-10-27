// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Music preferences use plain grouped rows, with explanations outside the cards.
struct SettingsView: View {
    @Environment(\.appContainer) private var container
    @ObservedObject private var appleMusic = AppleMusicSettings.shared
    @AppStorage("cassette.history.enabled") private var listeningHistoryEnabled = true
    @AppStorage("cassette.visuals.immersiveAlbums") private var immersiveAlbums = true
    @AppStorage("cassette.visuals.animatedArtwork") private var animatedArtwork = true
    @AppStorage("cassette.download.automaticAfterStreaming") private var automaticDownloadsEnabled = false
    @AppStorage("cassette.download.automaticOverCellular") private var automaticDownloadsOverCellular = false

    var body: some View {
        Form {
            librarySection
            audioSection
            downloadsSection
            displaySections
            accountSection
            appSection
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .cassetteContentWidth(.readable)
        .navigationTitle(Text("Music"))
        .onChange(of: immersiveAlbums) { _, _ in
            Task { await container?.nowPlayingService.refreshArtworkPresentation() }
        }
    }

    private var librarySection: some View {
        Section {
            Toggle(isOn: $appleMusic.enrichMetadata) {
                SettingsRowTitle("Enrich Album & Artist Info")
            }
        } header: {
            SettingsSectionHeader("Library")
        } footer: {
            SettingsSectionFooter("Fills missing album and artist descriptions from external sources.")
        }
    }

    private var audioSection: some View {
        Section {
            if let settings = container?.streamingSettings {
                SettingsNavigationRow("Dolby Atmos", value: SettingsOnOffChoice(settings.preferDolbyAtmos).choiceTitle) {
                    DolbyAtmosSettingsView(settings: settings)
                }
                SettingsNavigationRow("Audio Quality") {
                    AudioQualitySettingsView(settings: settings)
                }
            }
            if let replayGain = container?.replayGainSettings {
                Toggle(isOn: Binding(
                    get: { replayGain.enabled },
                    set: {
                        replayGain.enabled = $0
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    SettingsRowTitle("Volume Leveling")
                }
                if replayGain.enabled {
                    SettingsNavigationRow("Volume Leveling Options") { ReplayGainDetailSettingsView() }
                }
            }
            SettingsNavigationRow("Song Transitions", value: transitionValue) { PlaybackSettingsView() }
        } header: {
            SettingsSectionHeader("Audio")
        }
    }

    private var downloadsSection: some View {
        Section {
            SettingsNavigationRow("Downloaded Music") { DownloadedMusicManagementView() }
            SettingsNavigationRow("Storage") { StorageManagementView() }
            if let settings = container?.streamingSettings {
                SettingsNavigationRow("Download Quality", value: settings.effectiveDownloadFormat.title) {
                    DownloadQualitySettingsView(settings: settings)
                }
                Toggle("Download Dolby Atmos Version", isOn: Binding(
                    get: { settings.preferDolbyAtmosDownload },
                    set: { settings.preferDolbyAtmosDownload = $0 }
                ))
            }
            Toggle(isOn: $automaticDownloadsEnabled) {
                SettingsRowTitle("Automatic Downloads")
            }
            if automaticDownloadsEnabled {
                Toggle(isOn: $automaticDownloadsOverCellular) {
                    SettingsRowTitle("Automatic Downloads over Cellular")
                }
            }
        } header: {
            SettingsSectionHeader("Downloads")
        } footer: {
            VStack(alignment: .leading, spacing: CassetteSpacing.s) {
                SettingsSectionFooter("Automatically saves songs after playback begins. Cellular downloads use mobile data and can be turned off separately.")
                SettingsSectionFooter("Dolby Atmos downloads in Now Playing and Automatic Downloads preserve the original spatial file when a matching version is available. Otherwise, your download quality applies. Existing downloads are unchanged.")
            }
        }
    }

    @ViewBuilder
    private var displaySections: some View {
        Section {
            SettingsNavigationRow("Lyrics & Translation") { LyricsSettingsView() }
            Toggle(isOn: $immersiveAlbums) {
                SettingsRowTitle("Immersive Album Artwork")
            }
            Toggle(isOn: $animatedArtwork) {
                SettingsRowTitle("Animated Background")
            }
        } header: {
            SettingsSectionHeader("Display & Lyrics")
        } footer: {
            SettingsSectionFooter("Customize lyrics sources, translations, and whether album covers extend across player surfaces.")
        }

        Section {
            Toggle(isOn: $listeningHistoryEnabled) {
                SettingsRowTitle("Use Listening History")
            }
        } header: {
            SettingsSectionHeader("History")
        } footer: {
            SettingsSectionFooter("Listening activity on this device is used for Recently Played and Listening Replay.")
        }
    }

    private var accountSection: some View {
        Section {
            if let server = container?.serverState.activeServer {
                SettingsNavigationRow("Account", value: server.username) { AccountSettingsView() }
                if let service = container?.serverService {
                    SettingsNavigationRow("Server", value: server.displayName) {
                        EditServerDestinationView(server: server, serverService: service)
                    }
                }
            } else {
                SettingsValueRow("No Server Configured")
            }
        } header: {
            SettingsSectionHeader("Account")
        }
    }

    private var appSection: some View {
        Section {
            SettingsNavigationRow("Current Playback") { CurrentPlaybackSettingsView() }
            SettingsNavigationRow("Sharing") { SharingSettingsView() }
            SettingsActionRow("System Permissions") { CassetteSystemSettings.openAppSettings() }
            SettingsNavigationRow("Advanced") { AdvancedSettingsView() }
            SettingsNavigationRow("Developer") { DeveloperSettingsView() }
            SettingsNavigationRow("About") { AboutSettingsView() }
        } header: {
            SettingsSectionHeader("App")
        }
    }

    private var transitionValue: String {
        if let duration = container?.crossfadeSettings.duration, duration > 0 {
            return String(localized: "Crossfade", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        if container?.gaplessSettings.isEnabled == true {
            return String(localized: "Gapless Playback", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return SettingsOnOffChoice.off.choiceTitle
    }
}
