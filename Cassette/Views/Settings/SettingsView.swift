// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Settings root, organized the way Apple Music organizes its own preferences:
/// a handful of short groups of plain rows, no per-row explanation, and every
/// detail behind a chevron.
struct SettingsView: View {
    @Environment(\.appContainer) private var container

    private var server: ServerSnapshot? { container?.serverState.activeServer }

    private var serverHost: String? {
        guard let url = server?.baseURL, !url.isEmpty else { return nil }
        return url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        Form {
            accountSection
            playbackSection
            contentSection
            appSection
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .cassetteContentWidth(.readable)
        .navigationTitle(Text("Settings"))
    }

    // MARK: - 계정

    private var accountSection: some View {
        Section {
            if let server {
                SettingsNavigationRow("Account", value: server.username) {
                    AccountSettingsView()
                }

                if let serverService = container?.serverService {
                    SettingsNavigationRow("Server", value: serverHost) {
                        EditServerDestinationView(server: server, serverService: serverService)
                    }
                }
            } else {
                SettingsValueRow("No Server Configured")
            }
        }
    }

    // MARK: - 재생

    private var playbackSection: some View {
        Section {
            SettingsNavigationRow("Playback") {
                PlaybackSettingsView()
            }

            if let streamingSettings = container?.streamingSettings {
                SettingsNavigationRow("Audio Quality") {
                    AudioQualitySettingsView(settings: streamingSettings)
                }
            }
        } header: {
            SettingsSectionHeader("Playback")
        }
    }

    // MARK: - 콘텐츠

    private var contentSection: some View {
        Section {
            SettingsNavigationRow("Lyrics & Translation") {
                LyricsSettingsView()
            }

            SettingsNavigationRow("Content & Display") {
                ContentDisplaySettingsView()
            }

            SettingsNavigationRow("Sharing") {
                SharingSettingsView()
            }
        } header: {
            SettingsSectionHeader("Content")
        }
    }

    // MARK: - 앱

    private var appSection: some View {
        Section {
            SettingsNavigationRow("Storage") {
                StorageManagementView()
            }

            SettingsActionRow("System Permissions") {
                CassetteSystemSettings.openAppSettings()
            }

            SettingsNavigationRow("Advanced") {
                AdvancedSettingsView()
            }

            SettingsNavigationRow("About") {
                AboutSettingsView()
            }
        } header: {
            SettingsSectionHeader("App")
        }
    }
}
