// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct OnboardingExternalProvidersStepView: View {
    let onSkip: () -> Void
    let onContinue: () -> Void
    var stepIndex = 3
    var totalSteps = 4

    @Environment(\.appContainer) private var container
    @State private var vm: ExternalProvidersSettingsViewModel?
    @State private var showingAdd = false
    @State private var editingProvider: ExternalReleaseProvider?

    var body: some View {
        OnboardingStepView(
            icon: "arrow.up.right",
            title: String(localized: "Open Releases In", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "Add a provider to look up albums on Discogs, MusicBrainz, or anywhere you like.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            onSkip: onSkip,
            onContinue: onContinue
        ) {
            if let vm {
                providersSections(vm: vm)
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            if let vm {
                NavigationStack {
                    ExternalProviderEditView(mode: .new) { vm.save($0) }
                }
            }
        }
        .sheet(item: $editingProvider) { provider in
            if let vm {
                NavigationStack {
                    ExternalProviderEditView(mode: .edit(provider), onSave: { vm.save($0) }) {
                        vm.delete(provider)
                    }
                }
            }
        }
        .onAppear {
            if vm == nil, let store = container?.externalProvidersStore {
                vm = ExternalProvidersSettingsViewModel(store: store)
            }
        }
    }

    @ViewBuilder
    private func providersSections(vm: ExternalProvidersSettingsViewModel) -> some View {
        Section {
            if vm.providers.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "No providers yet", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        Text(String(localized: "Releases open in ListenBrainz by default.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    SettingsIcon(systemImage: "tray", color: .gray)
                }
            } else {
                ForEach(vm.providers) { provider in
                    Button {
                        editingProvider = provider
                    } label: {
                        Label {
                            Text(provider.name)
                                .foregroundStyle(.primary)
                        } icon: {
                            SettingsIcon(systemImage: "link", color: .teal)
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "Edit", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { editingProvider = provider }
                        Button(String(localized: "Delete", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) { vm.delete(provider) }
                    }
                }
            }

            Button {
                showingAdd = true
            } label: {
                Label {
                    Text(String(localized: "Add Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "plus", color: .blue)
                }
            }
        } header: {
            Text(String(localized: "Providers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "You can change this later in Settings.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }
}
