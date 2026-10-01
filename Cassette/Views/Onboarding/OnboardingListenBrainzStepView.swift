// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct OnboardingListenBrainzStepView: View {
    let onSkip: () -> Void
    let onContinue: () -> Void
    var stepIndex = 2
    var totalSteps = 4

    @Environment(\.appContainer) private var container
    @State private var vm: ListenBrainzSettingsViewModel?
    @State private var showDisconnectAlert = false

    var body: some View {
        OnboardingStepView(
            icon: "chart.line.uptrend.xyaxis",
            title: String(localized: "ListenBrainz", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "Connect your ListenBrainz account to log your plays and discover your listening stats.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            onSkip: onSkip,
            onContinue: onContinue
        ) {
            if let vm {
                connectionSections(vm: vm)
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
        .alert(String(localized: "Disconnect from ListenBrainz?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isPresented: $showDisconnectAlert) {
            if let vm {
                Button(String(localized: "Disconnect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                    Task { await vm.resetCredentials() }
                }
            }
            Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {}
        } message: {
            Text(String(localized: "Your username will be removed. You can reconnect anytime.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
        .task {
            guard let container else { return }
            if vm == nil {
                vm = ListenBrainzSettingsViewModel(service: container.listenBrainzService)
            }
            await vm?.refreshSnapshot()
            if let username = vm?.snapshot.username, vm?.snapshot.isEnabled == false {
                vm?.usernameInput = username
            }
        }
    }

    @ViewBuilder
    private func connectionSections(vm: ListenBrainzSettingsViewModel) -> some View {
        if vm.snapshot.isEnabled, let username = vm.snapshot.username {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text(String(localized: "Active", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label {
                        Text(username)
                    } icon: {
                        SettingsIcon(systemImage: "person.crop.circle.fill", color: CassetteColors.accent)
                    }
                }

                Button(String(localized: "Disconnect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                    showDisconnectAlert = true
                }
                .disabled(vm.isProcessing)
            } header: {
                Text(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        } else {
            notConnectedSection(vm: vm)
        }
    }

    @ViewBuilder
    private func notConnectedSection(vm: ListenBrainzSettingsViewModel) -> some View {
        @Bindable var vm = vm
        Section {
            TextField(String(localized: "ListenBrainz username", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $vm.usernameInput)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .onChange(of: vm.usernameInput) { _, _ in
                    vm.validateUsernameInputLocally()
                }

            if let error = vm.usernameInputValidationError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await vm.connect() }
            } label: {
                HStack {
                    if vm.isProcessing { ProgressView().scaleEffect(0.8) }
                    Text(String(localized: "Connect", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
            }
            .disabled(vm.usernameInput.isEmpty || vm.usernameInputValidationError != nil || vm.isProcessing)

            if let error = vm.userFacingError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(String(localized: "Account", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "You can change this later in Settings.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }
}
