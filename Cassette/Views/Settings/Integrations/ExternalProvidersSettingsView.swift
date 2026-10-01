// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - ViewModel

@Observable
@MainActor
final class ExternalProvidersSettingsViewModel {
    private let store: ExternalProvidersStore
    private(set) var providers: [ExternalReleaseProvider] = []

    init(store: ExternalProvidersStore) {
        self.store = store
        self.providers = store.load()
    }

    func save(_ provider: ExternalReleaseProvider) {
        if providers.contains(where: { $0.id == provider.id }) {
            store.update(provider)
        } else {
            store.add(provider)
        }
        providers = store.load()
    }

    func delete(_ provider: ExternalReleaseProvider) {
        store.remove(id: provider.id)
        providers = store.load()
    }
}

// MARK: - View

struct ExternalProvidersSettingsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var vm: ExternalProvidersSettingsViewModel?
    @State private var showingAdd = false
    @State private var editingProvider: ExternalReleaseProvider?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(String(localized: "Open Releases In", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "Add Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
            }
        }
        #endif
        .sheet(isPresented: $showingAdd) {
            if let vm {
                #if os(macOS)
                ExternalProviderEditView(mode: .new) { vm.save($0) }
                    .frame(minWidth: 400, minHeight: 300)
                #else
                NavigationStack {
                    ExternalProviderEditView(mode: .new) { vm.save($0) }
                }
                #endif
            }
        }
        .sheet(item: $editingProvider) { provider in
            if let vm {
                #if os(macOS)
                ExternalProviderEditView(mode: .edit(provider), onSave: { vm.save($0) }) {
                    vm.delete(provider)
                }
                .frame(minWidth: 400, minHeight: 300)
                #else
                NavigationStack {
                    ExternalProviderEditView(mode: .edit(provider), onSave: { vm.save($0) }) {
                        vm.delete(provider)
                    }
                }
                #endif
            }
        }
        .onAppear {
            if vm == nil, let store = container?.externalProvidersStore {
                vm = ExternalProvidersSettingsViewModel(store: store)
            }
        }
    }

    @ViewBuilder
    private func content(vm: ExternalProvidersSettingsViewModel) -> some View {
        if vm.providers.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "No Providers Configured", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.up.forward.square")
            } description: {
                Text(String(localized: "Add a custom search provider to open releases in your service of choice. Without a provider, releases fall back to ListenBrainz.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            } actions: {
                Button(String(localized: "Add Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { showingAdd = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    ForEach(vm.providers) { provider in
                        Button {
                            editingProvider = provider
                        } label: {
                            Label {
                                HStack {
                                    Text(provider.name)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            } icon: {
                                SettingsIcon(systemImage: "magnifyingglass", color: .orange)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(String(localized: "Edit", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { editingProvider = provider }
                            Button(String(localized: "Delete", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) { vm.delete(provider) }
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { vm.delete(vm.providers[i]) }
                    }
                } footer: {
                    Text(String(localized: "URL template must contain %s — replaced by \"Artist Album\" when opening a release.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }

                Section {
                    Button {
                        showingAdd = true
                    } label: {
                        Label {
                            Text(String(localized: "Add Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "plus", color: .blue)
                        }
                    }
                }
            }
            .modifier(SettingsSubpageStyle())
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }
}
