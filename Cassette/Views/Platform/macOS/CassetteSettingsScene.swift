// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftData

struct CassetteSettingsScene: Scene {
    let container: AppContainer?

    var body: some Scene {
        Settings {
            Group {
                if let container {
                    MacOSSettingsView()
                        .environment(\.appContainer, container)
                        .environment(container.dominantColorExtractor)
                        .environment(container.artworkImageCache)
                        .modelContainer(container.modelContainer)
                        // ToastService is intentionally absent: no Settings view or sheet
                        // currently reads @Environment(ToastService.self). Add it here if
                        // toastOverlay() is ever applied inside the Settings scene.
                } else {
                    ProgressView()
                        .frame(width: 480, height: 300)
                }
            }
        }
    }
}

// MARK: - Tab container

let cassetteSettingsSelectedTabKey = "cassette.settings.selectedTab"

enum SettingsTab: Int {
    case general, account, playback, library, integrations, about
}

struct MacOSSettingsView: View {
    @AppStorage(cassetteSettingsSelectedTabKey) private var selectedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)

            ServerSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account.rawValue)

            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(SettingsTab.playback.rawValue)

            CacheSettingsTab()
                .tabItem { Label("Library", systemImage: "externaldrive") }
                .tag(SettingsTab.library.rawValue)

            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "link.circle") }
                .tag(SettingsTab.integrations.rawValue)

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 560)
    }
}

// MARK: - Playback tab

private struct PlaybackSettingsTab: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Form {
            if let streamingSettings = container?.streamingSettings {
                MacAudioQualitySettingsSection(settings: streamingSettings)
            }
            ReplayGainSettingsSection()
            GaplessSettingsSection()
            CrossfadeSettingsSection()
        }
        .formStyle(.grouped)
        .frame(maxWidth: 540)
    }
}

private struct MacAudioQualitySettingsSection: View {
    @Bindable var settings: StreamingSettings

    var body: some View {
        Section {
            qualityPicker(
                "Cellular Streaming",
                systemImage: "antenna.radiowaves.left.and.right",
                selection: $settings.cellularFormat
            )
            qualityPicker(
                "Wi-Fi Streaming",
                systemImage: "wifi",
                selection: $settings.wifiFormat
            )
            qualityPicker(
                "Downloads",
                systemImage: "arrow.down.circle.fill",
                selection: $settings.downloadFormat
            )
        } header: {
            Text("Audio Quality")
        } footer: {
            Text("Dolby Atmos and multichannel tracks always play in their original format.")
        }
    }

    private func qualityPicker(
        _ title: LocalizedStringKey,
        systemImage: String,
        selection: Binding<CacheFormat>
    ) -> some View {
        Picker(selection: selection) {
            ForEach(CacheFormat.allCases) { format in
                Text(format.displayName).tag(format)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .pickerStyle(.menu)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @ObservedObject private var appleMusic = AppleMusicSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Theme") {
                    Text("Follow System")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Cassette uses your system appearance setting.")
            }

            Section {
                Toggle("Enrich album & artist descriptions", isOn: $appleMusic.enrichMetadata)
                TextField("Spotify Client ID", text: $appleMusic.spotifyClientId)
                    .textFieldStyle(.roundedBorder)
                SecureField("Spotify Client Secret", text: $appleMusic.spotifyClientSecret)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Catalog Enrichment")
            } footer: {
                Text("Descriptions come from Wikipedia. Spotify Client ID/Secret (Client Credentials) are used for ISRC lookup.")
            }

            LyricsSettingsSections()
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
    }
}

// MARK: - Server tab

private struct ServerSettingsTab: View {
    @Environment(\.appContainer) private var container
    @State private var showEditServer = false
    @State private var showAccount = false

    var body: some View {
        Form {
            Section("Server") {
                if let server = container?.serverState.activeServer,
                   let serverService = container?.serverService {
                    Button {
                        showEditServer = true
                    } label: {
                        LabeledContent("Server Configuration") {
                            HStack(spacing: CassetteSpacing.xs) {
                                Text(server.displayName)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showEditServer) {
                        EditServerDestinationView(server: server, serverService: serverService)
                            .frame(minWidth: 480, minHeight: 400)
                    }
                } else {
                    Text("No server configured.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    showAccount = true
                } label: {
                    HStack {
                        Label("Account", systemImage: "person.crop.circle")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let username = container?.serverState.activeServer?.username {
                            Text(username)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Account")
            } footer: {
                Text("Log out, change password, sync library data, media scans, and Spotify credentials.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .sheet(isPresented: $showAccount) {
            NavigationStack {
                AccountSettingsView()
            }
            .frame(minWidth: 480, minHeight: 520)
        }
    }
}

// MARK: - Cache tab

private struct CacheSettingsTab: View {
    @Environment(\.appContainer) private var container
    @State private var downloadsVM: DownloadsViewModel?
    @State private var showStorageManagement = false

    var body: some View {
        Form {
            Button {
                showStorageManagement = true
            } label: {
                HStack {
                    Label(String(localized: "Storage Management", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "internaldrive.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let downloadsVM {
                DownloadsSectionView(vm: downloadsVM)
            }
            CacheSectionView()
        }
        .formStyle(.grouped)
        .frame(maxWidth: 540)
        .task {
            guard let container else { return }
            if downloadsVM == nil {
                downloadsVM = DownloadsViewModel(
                    modelContainer: container.modelContainer,
                    downloadService: container.downloadService,
                    serverState: container.serverState
                )
            }
            await downloadsVM?.loadData()
        }
        .sheet(isPresented: $showStorageManagement) {
            NavigationStack {
                StorageManagementView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showStorageManagement = false }
                        }
                    }
            }
            .frame(minWidth: 560, minHeight: 560)
        }
    }
}

// MARK: - Integrations tab

private struct IntegrationsSettingsTab: View {
    @State private var showListenBrainz = false
    @State private var showProviders = false

    var body: some View {
        Form {
            Section {
                Button { showListenBrainz = true } label: {
                    HStack {
                        Label("ListenBrainz", systemImage: "link.circle")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { showProviders = true } label: {
                    HStack {
                        Label("Open Releases In", systemImage: "arrow.up.right.square")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
        .sheet(isPresented: $showListenBrainz) {
            ListenBrainzSettingsView()
                .frame(minWidth: 400, minHeight: 300)
        }
        .sheet(isPresented: $showProviders) {
            ExternalProvidersSettingsView()
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}

// MARK: - About tab

private struct AboutSettingsTab: View {
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildIdentifier: String {
        Bundle.main.infoDictionary?["CassetteBuildIdentifier"] as? String ?? "26A1001e"
    }
    private var copyrightNotice: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "© 2026 Kyumin"
    }

    var body: some View {
        Form {
            Section("Cassette") {
                LabeledContent("Version") {
                    Text(verbatim: "\(appVersion) (\(buildIdentifier))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("License") {
                    Text("MPL-2.0")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Copyright") {
                    Text(verbatim: copyrightNotice)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Links") {
                OnboardingReplayButton()
                Link(destination: CassetteURLs.cassette) {
                    Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "mailto:support@getcassette.app?subject=Feedback%20%2F%20Bug%20Report")!) {
                    Label("Send Feedback / Report a Bug", systemImage: "envelope")
                }
            }
            Section("Third-party") {
                LabeledContent("SwiftSonic") {
                    Text("MIT License")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("AudioStreaming") {
                    Link("dimitris-c", destination: CassetteURLs.audioStreaming)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }
}
#endif
