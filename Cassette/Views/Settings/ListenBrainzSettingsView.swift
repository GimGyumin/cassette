// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct ListenBrainzSettingsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ListenBrainzSettingsViewModel?
    @State private var showForgetAlert = false
    @State private var showForgetScrobblingAlert = false

    var body: some View {
        Group {
            if let vm = viewModel {
                Form {
                    aboutSection()
                    connectionSection(vm: vm)
                    scrobblingToggleSection(vm: vm)
                    scrobblingConfigSection(vm: vm)
                }
                .formStyle(.grouped)
                .modifier(SettingsSubpageStyle())
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(String(localized: "ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
            }
        }
        #endif
        .task {
            guard let container else { return }
            if viewModel == nil {
                viewModel = ListenBrainzSettingsViewModel(service: container.listenBrainzService)
            }
            await viewModel?.refreshSnapshot()
            await viewModel?.refreshScrobblingSnapshot()
        }
    }

    // MARK: - About

    private func aboutSection() -> some View {
        Section {
            Label {
                Text(String(localized: "ListenBrainz is an open-source music scrobbling and recommendation service by the MetaBrainz Foundation. Cassette can submit your listening history and surface personalized fresh releases and similar artists.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                SettingsIcon(systemImage: "waveform.path.ecg", color: .red)
            }
            Button {
                ExternalLinkOpener.open(CassetteURLs.listenBrainz)
            } label: {
                Label {
                    Text(String(localized: "Visit ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "safari.fill", color: .blue)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "About ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    // MARK: - Recommendations connection

    @ViewBuilder
    private func connectionSection(vm: ListenBrainzSettingsViewModel) -> some View {
        let snap = vm.snapshot
        if snap.isEnabled, let username = snap.username {
            connectedSection(vm: vm, username: username, status: snap.validationStatus)
        } else if let username = snap.username {
            previouslyConnectedSection(vm: vm, username: username)
        } else {
            notConnectedSection(vm: vm)
        }
    }

    private func notConnectedSection(vm: ListenBrainzSettingsViewModel) -> some View {
        @Bindable var vm = vm
        return Section {
            SettingsTextFieldRow(title: "Username", systemImage: "person.fill", color: .blue) {
                TextField(String(localized: "Username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $vm.usernameInput)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .onChange(of: vm.usernameInput) { _, _ in
                        vm.validateUsernameInputLocally()
                    }
            }

            Button {
                Task { await vm.connect() }
            } label: {
                Label {
                    HStack(spacing: CassetteSpacing.s) {
                        Text(String(localized: "Connect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        if vm.isProcessing {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                } icon: {
                    SettingsIcon(systemImage: "link.circle.fill", color: .blue)
                }
            }
            .disabled(vm.usernameInput.isEmpty || vm.usernameInputValidationError != nil || vm.isProcessing)

            if let error = vm.userFacingError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Recommendations Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            if let error = vm.usernameInputValidationError {
                Text(error).foregroundStyle(.red)
            } else {
                Text(String(localized: "Enter your ListenBrainz username to enable music recommendations.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
    }

    @ViewBuilder
    private func connectedSection(
        vm: ListenBrainzSettingsViewModel,
        username: String,
        status: ValidationStatus
    ) -> some View {
        Section {
            LabeledContent {
                Text(username).fontWeight(.medium)
            } label: {
                Label {
                    Text(String(localized: "Connected as", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.crop.circle.fill", color: .blue)
                }
            }
            LabeledContent {
                statusBadge(for: status)
            } label: {
                Label {
                    Text(String(localized: "Status", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "checkmark.circle.fill", color: statusColor(for: status))
                }
            }
            if case .invalid = status {
                Button {
                    Task { await vm.revalidate() }
                } label: {
                    Label {
                        HStack(spacing: CassetteSpacing.s) {
                            if vm.isProcessing { ProgressView().scaleEffect(0.8) }
                            Text(String(localized: "Retry connection", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        }
                    } icon: {
                        SettingsIcon(systemImage: "arrow.clockwise", color: .orange)
                    }
                }
                .disabled(vm.isProcessing)
            }
            if let error = vm.userFacingError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Recommendations Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }

        Section {
            Button {
                Task { await vm.disconnect() }
            } label: {
                Label {
                    HStack(spacing: CassetteSpacing.s) {
                        if vm.isProcessing { ProgressView().scaleEffect(0.8) }
                        Text(String(localized: "Disconnect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                } icon: {
                    SettingsIcon(systemImage: "pause.circle.fill", color: .gray)
                }
            }
            .disabled(vm.isProcessing)

            Button(role: .destructive) {
                showForgetAlert = true
            } label: {
                Label {
                    Text(String(localized: "Forget username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "trash.fill", color: .red)
                }
            }
        }
        .cassetteDestructiveAlert(
            String(localized: "Forget ListenBrainz Account?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showForgetAlert,
            message: String(localized: "Your username will be removed. You can reconnect anytime.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            destructiveButtonTitle: String(localized: "Forget", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            Task { await vm.resetCredentials() }
        }
    }

    @ViewBuilder
    private func previouslyConnectedSection(vm: ListenBrainzSettingsViewModel, username: String) -> some View {
        Section {
            LabeledContent {
                Text(username).fontWeight(.medium)
            } label: {
                Label {
                    Text(String(localized: "Previously connected as", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.crop.circle.badge.clock", color: .orange)
                }
            }

            Button {
                vm.usernameInput = username
                Task { await vm.connect() }
            } label: {
                Label {
                    HStack(spacing: CassetteSpacing.s) {
                        Text(String(localized: "Reconnect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        if vm.isProcessing { ProgressView().scaleEffect(0.8) }
                    }
                } icon: {
                    SettingsIcon(systemImage: "arrow.clockwise.circle.fill", color: .blue)
                }
            }
            .disabled(vm.isProcessing)

            Button(role: .destructive) {
                showForgetAlert = true
            } label: {
                Label {
                    Text(String(localized: "Forget username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "trash.fill", color: .red)
                }
            }

            if let error = vm.userFacingError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Recommendations Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
        .cassetteDestructiveAlert(
            String(localized: "Forget ListenBrainz Account?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showForgetAlert,
            message: String(localized: "Your username will be removed. You can reconnect anytime.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            destructiveButtonTitle: String(localized: "Forget", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            Task { await vm.resetCredentials() }
        }
    }

    // MARK: - Scrobbling

    private func scrobblingToggleSection(vm: ListenBrainzSettingsViewModel) -> some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { vm.isScrobblingToggleOn },
                    set: { on in Task { await vm.toggleScrobbling(on) } }
                )
            ) {
                Label {
                    Text(String(localized: "Submit listens to ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "dot.radiowaves.left.and.right", color: .red)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Scrobbling", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "If your server already relays listens to ListenBrainz, leave this disabled to avoid duplicate scrobbles.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    @ViewBuilder
    private func scrobblingConfigSection(vm: ListenBrainzSettingsViewModel) -> some View {
        if case .connected(let username) = vm.scrobblingConnectionState {
            scrobblingConnectedSection(vm: vm, username: username)
        } else if vm.isScrobblingToggleOn {
            scrobblingInputSection(vm: vm)
        }
    }

    private func scrobblingInputSection(vm: ListenBrainzSettingsViewModel) -> some View {
        @Bindable var vm = vm
        return Section {
            SettingsTextFieldRow(title: "User token", systemImage: "key.fill", color: .orange) {
                SecureField(String(localized: "User token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $vm.tokenInput)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
            }

            SettingsTextFieldRow(title: "Server URL", systemImage: "network", color: .gray) {
                TextField(String(localized: "Server URL", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $vm.serverURLInput)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }

            Button {
                Task { await vm.validateScrobblingToken() }
            } label: {
                Label {
                    HStack(spacing: CassetteSpacing.s) {
                        Text(String(localized: "Validate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        if case .validating = vm.scrobblingConnectionState {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                } icon: {
                    SettingsIcon(systemImage: "checkmark.seal.fill", color: .green)
                }
            }
            .disabled(vm.tokenInput.isEmpty || vm.isScrobblingProcessing)

            if case .failed(let message) = vm.scrobblingConnectionState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "Find your user token at listenbrainz.org > Profile > Music Services & API.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    @ViewBuilder
    private func scrobblingConnectedSection(vm: ListenBrainzSettingsViewModel, username: String?) -> some View {
        Section {
            LabeledContent {
                Text(username ?? String(localized: "ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).fontWeight(.medium)
            } label: {
                Label {
                    Text(String(localized: "Connected as", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "person.crop.circle.fill", color: .blue)
                }
            }
            LabeledContent {
                Text(vm.scrobblingSnapshot.isEnabled ? String(localized: "Active", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Paused", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .foregroundStyle(vm.scrobblingSnapshot.isEnabled ? .green : .secondary)
            } label: {
                Label {
                    Text(String(localized: "Scrobbling", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "dot.radiowaves.left.and.right", color: vm.scrobblingSnapshot.isEnabled ? .green : .gray)
                }
            }
            Button {
                vm.startTokenReplacement()
            } label: {
                Label {
                    Text(String(localized: "Replace token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "key.fill", color: .orange)
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Token", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }

        Section {
            Button(role: .destructive) {
                showForgetScrobblingAlert = true
            } label: {
                Label {
                    Text(String(localized: "Forget credentials", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "trash.fill", color: .red)
                }
            }
            .disabled(vm.isScrobblingProcessing)
        }
        .cassetteDestructiveAlert(
            String(localized: "Forget Scrobbling Credentials?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showForgetScrobblingAlert,
            message: String(localized: "Your token will be removed and scrobbling disabled. You can reconnect anytime.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            destructiveButtonTitle: String(localized: "Forget", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            Task { await vm.resetScrobblingToken() }
        }
    }

    // MARK: - Status badge

    private func statusBadge(for status: ValidationStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: status))
                .frame(width: 8, height: 8)
            Text(statusLabel(for: status))
                .font(.caption)
                .foregroundStyle(statusColor(for: status))
        }
    }

    private func statusColor(for status: ValidationStatus) -> Color {
        switch status {
        case .valid: .green
        case .validating, .unknown: .orange
        case .invalid: .red
        }
    }

    private func statusLabel(for status: ValidationStatus) -> String {
        switch status {
        case .valid: String(localized: "Connected", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .validating: String(localized: "Validating…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .unknown: String(localized: "Validation pending", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .invalid: String(localized: "Connection issue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}
