// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import OSLog
import SwiftSonic
import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appleMusicSettings = AppleMusicSettings.shared

    @State private var user: User?
    @State private var capabilities: ServerCapabilities?
    @State private var scanStatus: ScanStatus?
    @State private var isLoadingInfo = false
    @State private var isSyncing = false
    @State private var isScanning = false
    @State private var isGeneratingLyrics = false
    @State private var isGeneratingServerFiles = false
    @State private var lyricsGenerationTask: Task<Void, Never>?
    @State private var lyricsGenerationProgress: LyricsService.LibraryLyricsProgress?
    @State private var lyricsGenerationLog: [LyricsService.LibraryLyricsEvent] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showChangePassword = false
    @State private var showLogoutConfirm = false
    @State private var pollTask: Task<Void, Never>?
    @State private var clientIdDraft = ""
    @State private var clientSecretDraft = ""
    @State private var credentialsSavedFlash = false
    @State private var appleMusicTokenDraft = ""
    @State private var appleMusicStorefrontDraft = ""
    @State private var appleMusicSavedFlash = false

    private var server: ServerSnapshot? { container?.serverState.activeServer }

    var body: some View {
        Form {
            accountSection
            librarySection
            isrcCatalogSection
            spotifyCredentialsSection
            serverInfoSection
            sessionSection
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            clientIdDraft = appleMusicSettings.spotifyClientId
            clientSecretDraft = appleMusicSettings.spotifyClientSecret
            appleMusicTokenDraft = appleMusicSettings.appleMusicDeveloperToken
            appleMusicStorefrontDraft = appleMusicSettings.appleMusicStorefront
            await loadInfo()
        }
        .onDisappear {
            pollTask?.cancel()
            lyricsGenerationTask?.cancel()
        }
        .sheet(isPresented: $showChangePassword) {
            if let server, let serverService = container?.serverService {
                ChangePasswordSheet(server: server, serverService: serverService)
            }
        }
        .cassetteDestructiveAlert(
            String(localized: "Log Out?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showLogoutConfirm,
            message: String(localized: "This removes saved servers, downloads, caches, Home pins, and local search history from this device. Settings and iCloud listening history are kept.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            destructiveButtonTitle: String(localized: "Log Out", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            Task { await logOut() }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            LabeledContent {
                Text(server?.username ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.circle.fill", color: Color.cassetteAccent)
                }
            }
            if let email = user?.email, !email.isEmpty {
                LabeledContent {
                    Text(email)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Label {
                        Text(String(localized: "Email", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "envelope.fill", color: .blue)
                    }
                }
            }
            LabeledContent {
                Text(user?.adminRole == true
                      ? String(localized: "Administrator", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                      : String(localized: "User", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Role", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.badge.shield.checkmark.fill", color: .indigo)
                }
            }
            if let maxBitRate = user?.maxBitRate {
                LabeledContent {
                    Text("\(maxBitRate) kbps")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Label {
                        Text(String(localized: "Max bitrate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "speedometer", color: .teal)
                    }
                }
            }
            Button {
                showChangePassword = true
            } label: {
                Label {
                    Text(String(localized: "Change Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                        SettingsIcon(systemImage: "lock.shield.fill", color: .orange)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Account Info", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Account details come from your Subsonic server. Changing the password updates the server and the Keychain on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var isrcCatalogSection: some View {
        Section {
            Picker(selection: $appleMusicSettings.isrcProvider) {
                Text(String(localized: "Spotify", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(ISRCProvider.spotify)
                Text(String(localized: "Apple Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(ISRCProvider.appleMusic)
            } label: {
                Label {
                    Text(String(localized: "ISRC provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "barcode.viewfinder", color: .purple)
                }
            }

            SettingsTextFieldRow(title: "Developer Token", systemImage: "key.fill", color: .orange) {
                TextField(String(localized: "Apple Music Developer Token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $appleMusicTokenDraft, axis: .vertical)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
                    .font(.caption.monospaced())
                    .textContentType(.none)
                    .lineLimit(3...6)
            }

            SettingsTextFieldRow(title: "Storefront", systemImage: "globe", color: .blue) {
                TextField(String(localized: "Storefront (optional, e.g. kr)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $appleMusicStorefrontDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
                    .font(.body.monospaced())
                    .textContentType(.none)
            }

            HStack {
                Button(String(localized: "Save", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    saveAppleMusicToken()
                }
                .disabled(!appleMusicTokenDraftChanged)

                Spacer()

                if appleMusicSettings.hasAppleMusicDeveloperToken {
                    Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                        appleMusicTokenDraft = ""
                        appleMusicStorefrontDraft = ""
                        appleMusicSettings.appleMusicDeveloperToken = ""
                        appleMusicSettings.appleMusicStorefront = ""
                        present(String(localized: "Apple Music token cleared.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                    }
                }
            }

            Link(destination: MusicKitDeveloperTokenInfo.generatingTokensURL) {
                Label(
                    String(localized: "Apple docs (paid Developer Program required)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    systemImage: "arrow.up.forward.app"
                )
                .font(.footnote)
            }

            if appleMusicSavedFlash {
                Text(String(localized: "Apple Music token saved.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent {
                Text(appleMusicTokenStatusLabel)
                    .foregroundStyle(appleMusicTokenStatusColor)
            } label: {
                Label {
                    Text(String(localized: "Token status", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "checkmark.seal.fill", color: appleMusicTokenStatusIconColor)
                }
            }

            if let updated = appleMusicTokenUpdatedDisplayDate {
                LabeledContent {
                    Text(updated.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(String(localized: "Last updated", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "clock.fill", color: .gray)
                    }
                }
            }

            if let expires = appleMusicSettings.appleMusicDeveloperTokenClaims?.expiresAt {
                LabeledContent {
                    Text(expires.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(appleMusicTokenStatusColor)
                } label: {
                    Label {
                        Text(String(localized: "Expires", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "calendar.badge.clock", color: appleMusicTokenStatusIconColor)
                    }
                }
            }

            if appleMusicTokenNeedsAttention {
                Text(appleMusicTokenWarningMessage)
                    .font(.footnote)
                    .foregroundStyle(appleMusicTokenStatusColor)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "ISRC / Music Haptics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Apple Music tokens need a paid Apple Developer Program membership ($99/yr) to create a MusicKit key. Without it, choose Spotify above or leave this empty — Cassette still uses free MusicBrainz for ISRC.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private var appleMusicTokenDraftChanged: Bool {
        appleMusicTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != appleMusicSettings.appleMusicDeveloperToken
            || appleMusicStorefrontDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            != appleMusicSettings.appleMusicStorefront
    }

    private func saveAppleMusicToken() {
        switch MusicKitDeveloperTokenInfo.validateForSave(appleMusicTokenDraft) {
        case .failure(let error):
            present(error.localizedDescription, error: true)
            return
        case .success(let token):
            let storefront = appleMusicStorefrontDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            appleMusicSettings.appleMusicDeveloperToken = token
            appleMusicSettings.appleMusicStorefront = storefront
            appleMusicTokenDraft = token
            appleMusicStorefrontDraft = storefront
            appleMusicSavedFlash = true
            present(
                token.isEmpty
                    ? String(localized: "Apple Music token cleared.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    : String(localized: "Apple Music token saved.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                error: false
            )
            Task {
                try? await Task.sleep(for: .seconds(2))
                appleMusicSavedFlash = false
            }
        }
    }

    private var appleMusicTokenClaims: MusicKitDeveloperTokenInfo.Claims? {
        appleMusicSettings.appleMusicDeveloperTokenClaims
    }

    private var appleMusicTokenUpdatedDisplayDate: Date? {
        appleMusicSettings.appleMusicDeveloperTokenUpdatedAt
            ?? appleMusicTokenClaims?.issuedAt
    }

    private var appleMusicTokenNeedsAttention: Bool {
        guard appleMusicSettings.hasAppleMusicDeveloperToken else { return false }
        guard let claims = appleMusicTokenClaims else { return false }
        return claims.needsReplacementSoon
    }

    private var appleMusicTokenStatusLabel: String {
        guard appleMusicSettings.hasAppleMusicDeveloperToken else {
            return String(localized: "Not set", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        guard let claims = appleMusicTokenClaims else {
            return String(localized: "Set (dates unknown)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        if claims.isExpired {
            return String(localized: "Expired — replace token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        if claims.needsReplacementSoon {
            return String(localized: "Expiring soon — replace token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(localized: "Valid", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private var appleMusicTokenStatusColor: Color {
        guard appleMusicSettings.hasAppleMusicDeveloperToken else { return .secondary }
        guard let claims = appleMusicTokenClaims else { return .secondary }
        if claims.isExpired { return .red }
        if claims.needsReplacementSoon { return .orange }
        return .secondary
    }

    private var appleMusicTokenStatusIconColor: Color {
        guard appleMusicSettings.hasAppleMusicDeveloperToken else { return .gray }
        guard let claims = appleMusicTokenClaims else { return .gray }
        if claims.isExpired { return .red }
        if claims.needsReplacementSoon { return .orange }
        return .green
    }

    private var appleMusicTokenWarningMessage: String {
        guard let claims = appleMusicTokenClaims else { return "" }
        if claims.isExpired {
            return String(localized: "This developer token has expired. Generate a new MusicKit JWT and paste it above.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(localized: "This developer token expires within 14 days. Replace it soon so Apple Music ISRC lookup keeps working.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private var spotifyCredentialsSection: some View {
        Section {
            SettingsTextFieldRow(title: "Client ID", systemImage: "person.text.rectangle.fill", color: .green) {
                TextField(String(localized: "Spotify Client ID", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $clientIdDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
                    .font(.body.monospaced())
                    // Avoid Password AutoFill injecting Apple ID / other secrets → invalid_client.
                    .textContentType(.none)
            }

            SettingsTextFieldRow(title: "Client Secret", systemImage: "lock.fill", color: .orange) {
                SecureField(String(localized: "Spotify Client Secret", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $clientSecretDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
                    .font(.body.monospaced())
                    .textContentType(.none)
            }

            HStack {
                Button(String(localized: "Save", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    saveSpotifyCredentials()
                }
                .disabled(
                    clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        == appleMusicSettings.spotifyClientId
                        && clientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        == appleMusicSettings.spotifyClientSecret
                )

                Spacer()

                if appleMusicSettings.hasSpotifyCredentials {
                    Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                        clientIdDraft = ""
                        clientSecretDraft = ""
                        appleMusicSettings.spotifyClientId = ""
                        appleMusicSettings.spotifyClientSecret = ""
                        present(String(localized: "Spotify credentials cleared.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                    }
                }
            }

            if credentialsSavedFlash {
                Text(String(localized: "Spotify credentials saved.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if appleMusicSettings.hasSpotifyCredentials {
                Text(String(localized: "Spotify credentials are saved on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Spotify", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Spotify Web API Client ID and Secret (Client Credentials) for ISRC. The Spotify account that owns the Developer app must have Premium (Spotify Dev Mode). If Spotify returns 403, Cassette falls back to MusicBrainz. Album descriptions still come from Wikipedia.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private func saveSpotifyCredentials() {
        let id = clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        appleMusicSettings.spotifyClientId = id
        appleMusicSettings.spotifyClientSecret = secret
        clientIdDraft = id
        clientSecretDraft = secret
        credentialsSavedFlash = true
        present(
            id.isEmpty || secret.isEmpty
                ? String(localized: "Spotify credentials cleared.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Spotify credentials saved.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            error: false
        )
        Task {
            try? await Task.sleep(for: .seconds(2))
            credentialsSavedFlash = false
        }
    }

    private var serverInfoSection: some View {
        Section {
            LabeledContent {
                Text(server?.displayName ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } label: {
                Label {
                    Text(String(localized: "Display Name", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "text.badge.checkmark", color: .gray)
                }
            }
            LabeledContent {
                Text(server?.baseURL ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } label: {
                Label {
                    Text(String(localized: "Address", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "globe", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.serverType ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Server Type", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "server.rack", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.serverVersion ?? server?.serverVersion ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "Server Version", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "info.circle.fill", color: .blue)
                }
            }
            LabeledContent {
                Text(capabilities?.apiVersion ?? "—")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text(String(localized: "API Version", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                        SettingsIcon(systemImage: "number.circle.fill", color: .purple)
                }
            }
            if isLoadingInfo {
                ProgressView()
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Server Info", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private var librarySection: some View {
        Section {
            Button {
                Task { await syncLibrary() }
            } label: {
                if isSyncing {
                    HStack(spacing: CassetteSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "Syncing…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                } else {
                    Label {
                        Text(String(localized: "Sync Library Data", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "arrow.triangle.2.circlepath.circle.fill", color: .blue)
                    }
                }
            }
            .disabled(isSyncing || isScanning)

            Button {
                Task { await startScan(.quick) }
            } label: {
                Label {
                    Text(String(localized: "Quick Scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "sparkles", color: .orange)
                }
            }
            .disabled(isScanning || isSyncing)

            Button {
                Task { await startScan(.full) }
            } label: {
                Label {
                    Text(String(localized: "Full Scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "internaldrive.fill", color: CassetteColors.accent)
                }
            }
            .disabled(isScanning || isSyncing)

            if isGeneratingLyrics {
                lyricsGenerationSection
            } else {
                Button {
                    startGeneratingLyrics()
                } label: {
                    Label {
                        Text(String(localized: "Generate Library Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "text.quote", color: .purple)
                    }
                }
                .disabled(isScanning || isSyncing)

                Button {
                    startGeneratingLyrics(serverFiles: true)
                } label: {
                    Label(String(localized: "Generate Server TTML Files", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "doc.badge.gearshape")
                }
                .disabled(isScanning || isSyncing)
                Text(String(localized: "Configure nd-lyrics with Apple Music, TTML, Write lyrics to sidecar files and library write access. Every song is requested from the server. File creation is handled by the plugin; check server logs for write errors.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let scanStatus {
                LabeledContent {
                    Text(scanStatus.scanning
                          ? String(localized: "Scanning…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                          : String(localized: "Idle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        Text(String(localized: "Scan Status", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "arrow.counterclockwise.circle.fill", color: .gray)
                    }
                }
                if let count = scanStatus.count {
                    LabeledContent {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(String(localized: "Files indexed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "doc.fill", color: .green)
                        }
                    }
                }
                if let folders = scanStatus.folderCount {
                    LabeledContent {
                        Text("\(folders)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text(String(localized: "Folders", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "folder.fill", color: .orange)
                        }
                    }
                }
                if let last = scanStatus.lastScan {
                    LabeledContent {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text(String(localized: "Last scan", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "clock.fill", color: CassetteColors.accent)
                        }
                    }
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Sync refreshes favorites and clears Cassette’s API caches. Quick Scan asks the server to rescan new or changed files; Full Scan forces a complete rescan when the server supports it (e.g. Navidrome).", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private var sessionSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label {
                    Text(String(localized: "Log Out", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "rectangle.portrait.and.arrow.right.fill", color: .red)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Session", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    // MARK: - Actions

    private func loadInfo() async {
        guard let container, let server else { return }
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        do {
            let client = try await container.serverService.makeSwiftSonicClient()
            async let userTask = client.getUser(username: server.username)
            async let capsTask = client.refreshCapabilities()
            async let scanTask = client.getScanStatus()
            user = try await userTask
            capabilities = try await capsTask
            scanStatus = try? await scanTask
        } catch {
            Logger.settings.error("Account info load failed: \(error.localizedDescription, privacy: .public)")
            present(String(localized: "Couldn’t load account info.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: true)
        }
    }

    private func syncLibrary() async {
        guard let container else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            await container.libraryService.invalidateClientCache()
            await container.playlistService.invalidateClientCache()
            await container.radioService.invalidateClientCache()
            try await container.favoritesService.syncFromServer()
            present(String(localized: "Library data synced.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
        } catch {
            Logger.settings.error("Library sync failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func startGeneratingLyrics(serverFiles: Bool = false) {
        guard let container, let server else { return }
        let lyricsService = container.lyricsService
        let libraryService = container.libraryService
        let serverId = server.id

        guard !isGeneratingLyrics else { return }
        isGeneratingServerFiles = serverFiles
        isGeneratingLyrics = true
        lyricsGenerationProgress = nil
        lyricsGenerationLog = []

        lyricsGenerationTask = Task { @MainActor in
            let stream = await lyricsService.generateLibraryLyrics(
                library: libraryService,
                serverId: serverId,
                mode: serverFiles ? .serverFiles : .appCache
            )
            do {
                for try await event in stream {
                    lyricsGenerationProgress = event.progress
                    lyricsGenerationLog.append(event)
                    if lyricsGenerationLog.count > 100 {
                        lyricsGenerationLog.removeFirst(lyricsGenerationLog.count - 100)
                    }
                }
                if Task.isCancelled {
                    present(String(localized: "Lyrics generation cancelled.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                } else if let progress = lyricsGenerationProgress {
                    present(
                        (serverFiles
                            ? String(localized: "Server lyrics requests complete.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                            : String(localized: "Library lyrics generation complete.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            + "  \(progress.found) / \(progress.total)",
                        error: false
                    )
                }
            } catch is CancellationError {
                present(String(localized: "Lyrics generation cancelled.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
            } catch {
                Logger.settings.error("Library lyrics generation failed: \(error.localizedDescription, privacy: .public)")
                present(error.localizedDescription, error: true)
            }
            isGeneratingLyrics = false
        }
    }

    private func cancelGeneratingLyrics() {
        lyricsGenerationTask?.cancel()
        lyricsGenerationTask = nil
    }

    @ViewBuilder
    private var lyricsGenerationSection: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            HStack {
                if let progress = lyricsGenerationProgress {
                    Text("\(progress.processed) / \(progress.total)")
                        .monospacedDigit()
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "Generating lyrics…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    cancelGeneratingLyrics()
                }
                .font(.footnote)
            }

            if let progress = lyricsGenerationProgress, progress.total > 0 {
                if isGeneratingServerFiles {
                    Text(String(localized: "Server responses", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) + "  ✓ \(progress.found) · × \(progress.missing + progress.failed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(progress.processed), total: Double(progress.total))
            }

            if !lyricsGenerationLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lyricsGenerationLog.suffix(20)), id: \.self) { event in
                        HStack(spacing: 6) {
                            Text(outcomeSymbol(event.outcome))
                                .foregroundStyle(outcomeColor(event.outcome))
                            Text(artistAndTitle(for: event))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(outcomeLabel(event.outcome))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func artistAndTitle(for event: LyricsService.LibraryLyricsEvent) -> String {
        if let artist = event.artist, !artist.isEmpty {
            return "\(event.songTitle) — \(artist)"
        }
        return event.songTitle
    }

    private func outcomeSymbol(_ outcome: LyricsService.LibraryLyricsEvent.Outcome) -> String {
        switch outcome {
        case .found(.karaoke): return "✓"
        case .found(.synced), .found(.unsynced): return "○"
        case .skipped: return "–"
        case .missing, .failed: return "×"
        }
    }

    private func outcomeColor(_ outcome: LyricsService.LibraryLyricsEvent.Outcome) -> Color {
        switch outcome {
        case .found(.karaoke): return .green
        case .found(.synced): return .orange
        case .found(.unsynced): return .gray
        case .skipped: return .gray
        case .missing, .failed: return .red
        }
    }

    private func outcomeLabel(_ outcome: LyricsService.LibraryLyricsEvent.Outcome) -> String {
        switch outcome {
        case .found(.karaoke): return isGeneratingServerFiles ? String(localized: "Word-synced", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : "TTML"
        case .found(.synced): return "LRC"
        case .found(.unsynced):
            return String(localized: "Text", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .skipped:
            return String(localized: "Skipped", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .failed(let message): return message
        case .missing:
            return String(localized: "No lyrics found", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    private func startScan(_ mode: LibraryScanMode) async {
        guard let container, let server else { return }
        isScanning = true
        present(
            mode == .full
                ? String(localized: "Starting full scan…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Starting quick scan…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            error: false
        )
        do {
            let status = try await LibraryScanService.startScan(
                mode: mode,
                baseURL: server.baseURL,
                username: server.username,
                serverService: container.serverService
            )
            scanStatus = status
            if status.scanning {
                present(String(localized: "Scan started on the server.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                beginPolling()
            } else {
                isScanning = false
                present(String(localized: "Scan finished.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                prepareLibraryAfterScan()
            }
        } catch {
            isScanning = false
            Logger.settings.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task {
            guard let container else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                do {
                    let status = try await LibraryScanService.status(
                        serverService: container.serverService
                    )
                    scanStatus = status
                    if !status.scanning {
                        isScanning = false
                        present(String(localized: "Scan finished.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), error: false)
                        prepareLibraryAfterScan()
                        break
                    }
                } catch {
                    isScanning = false
                    present(error.localizedDescription, error: true)
                    break
                }
            }
        }
    }

    /// A scan is how the user says "I just added music", so the local index and the artwork are
    /// prepared immediately instead of waiting for the next launch to notice the new file count.
    ///
    /// This is also the in-app trigger for the library-preparation Live Activity: it runs while the
    /// user is watching Settings, which is exactly the "task the user is actively tracking" case
    /// ActivityKit asks for. The pass itself still decides whether there is anything to do.
    private func prepareLibraryAfterScan() {
        guard let container else { return }
        Task {
            await container.libraryPreparationService.prepareIfLibraryChanged(
                serverService: container.serverService,
                libraryService: container.libraryService,
                indexService: container.libraryIndexService,
                coverPreload: container.albumCoverPreloadService
            )
        }
    }

    private func logOut() async {
        guard let container else { return }
        do {
            try await container.logOutAndClearLocalData()
            dismiss()
        } catch {
            Logger.settings.error("Log out failed: \(error.localizedDescription, privacy: .public)")
            present(error.localizedDescription, error: true)
        }
    }

    private func present(_ message: String, error: Bool) {
        statusMessage = message
        statusIsError = error
    }
}

// MARK: - Change password

private struct ChangePasswordSheet: View {
    let server: ServerSnapshot
    let serverService: any ServerServiceProtocol

    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !newPassword.isEmpty
            && newPassword == confirmPassword
            && newPassword.count >= 4
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsTextFieldRow(title: "New Password", systemImage: "lock.fill", color: .orange) {
                        SecureField(String(localized: "New Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $newPassword)
                            .textContentType(.newPassword)
                    }
                    SettingsTextFieldRow(title: "Confirm Password", systemImage: "checkmark.shield.fill", color: .green) {
                        SecureField(String(localized: "Confirm Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $confirmPassword)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    Text(String(localized: "The new password is sent to the server, then saved in the Keychain on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsSubpageStyle())
            .navigationTitle(String(localized: "Change Password", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Save", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
        #endif
    }

    private func save() async {
        guard newPassword == confirmPassword else {
            errorMessage = String(localized: "Passwords do not match.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let headers = (try? await serverService.activeCredentials())?.customHeaders ?? [:]
            let client = try await serverService.makeSwiftSonicClient()
            try await client.changePassword(username: server.username, newPassword: newPassword)
            try await serverService.updateServer(
                id: server.id,
                displayName: server.displayName,
                baseURL: server.baseURL,
                username: server.username,
                password: newPassword,
                customHeaders: headers
            )
            dismiss()
        } catch {
            Logger.settings.error("Change password failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }
}
