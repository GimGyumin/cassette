// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Account popup presented from the root-tab profile button.
///
/// This is the account home on iOS: the signed-in identity, the server it
/// connects to, and the optional services tied to that account
/// (ListenBrainz, external release links). App configuration lives in
/// `SettingsView`, reached from the last row.
struct AccountSheetView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var verificationServer: ServerSnapshot?

    private var server: ServerSnapshot? { container?.serverState.activeServer }
    private var hasServerService: Bool { container?.serverService != nil }

    private var displayName: String {
        server?.username ?? String(localized: "Not Signed In", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private var serverHost: String? {
        guard let url = server?.baseURL, !url.isEmpty else { return nil }
        return url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        NavigationStack {
            List {
                identitySection
                if let server, container?.serverState.needsSubsonicVerification == true {
                    Section {
                        Button { verificationServer = server } label: {
                            Label("Account Verification Required", systemImage: "person.crop.circle.badge.exclamationmark")
                                .padding(.vertical, 8)
                        }
                    }
                }
                LibraryPreparationAccountSection()
                if server != nil, hasServerService {
                    Section {
                        accountRow(title: "Server", value: serverHost, destination: .server)
                    }
                }
                servicesSection
                settingsSection
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle(Text("Account"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        dismiss()
                    }
                }
            }
            .navigationDestination(for: AccountSheetDestination.self) { destination in
                switch destination {
                case .account:
                    AccountSettingsView()
                case .server:
                    if let server, let serverService = container?.serverService {
                        EditServerDestinationView(server: server, serverService: serverService)
                    } else {
                        ContentUnavailableView(
                            String(localized: "No Server", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            systemImage: "server.rack",
                            description: Text(String(localized: "Add a server to configure it here.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        )
                    }
                case .listenBrainz:
                    ListenBrainzSettingsView()
                case .externalProviders:
                    ExternalProvidersSettingsView()
                case .preferences:
                    SettingsView()
                }
            }
        }
        .modifier(SettingsSubpageStyle())
        .modifier(SubsonicAccountVerificationAlert(server: $verificationServer))
    }

    // MARK: - 계정

    private var identitySection: some View {
        Section {
            NavigationLink(value: AccountSheetDestination.account) {
                HStack(spacing: CassetteSpacing.m) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(serverHost ?? String(localized: "No Server Configured", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, CassetteSpacing.xs)
            }
        } footer: {
            SettingsSectionFooter("Account details come from your server.")
        }
    }

    // MARK: - 서비스

    private var servicesSection: some View {
        Section {
            accountRow(
                title: "ListenBrainz",
                subtitle: "Scrobbling and recommendations",
                destination: .listenBrainz
            )

            accountRow(
                title: "External Apps",
                subtitle: "Open releases in another app",
                destination: .externalProviders
            )
        } header: {
            SettingsSectionHeader("Services")
        }
    }

    // MARK: - 앱

    private var settingsSection: some View {
        Section {
            accountRow(title: "Settings", value: nil, destination: .preferences)
        } header: {
            SettingsSectionHeader("App")
        }
    }

    private func accountRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: String? = nil,
        destination: AccountSheetDestination
    ) -> some View {
        NavigationLink(value: destination) {
            SettingsValueRow(title, subtitle: subtitle, value: value)
        }
    }
}

private enum AccountSheetDestination: Hashable {
    case account
    case server
    case listenBrainz
    case externalProviders
    case preferences
}
