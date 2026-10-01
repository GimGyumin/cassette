// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct ExternalProviderEditView: View {

    enum Mode {
        case new
        case edit(ExternalReleaseProvider)

        var title: String {
            switch self {
            case .new: return String(localized: "New Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            case .edit: return String(localized: "Edit Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            }
        }

        var existingID: UUID? {
            if case .edit(let p) = self { return p.id }
            return nil
        }
    }

    let mode: Mode
    let onSave: (ExternalReleaseProvider) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlTemplate: String
    @State private var showingDeleteConfirm = false

    init(mode: Mode, onSave: @escaping (ExternalReleaseProvider) -> Void, onDelete: (() -> Void)? = nil) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .new:
            _name = State(initialValue: "")
            _urlTemplate = State(initialValue: "")
        case .edit(let provider):
            _name = State(initialValue: provider.name)
            _urlTemplate = State(initialValue: provider.urlTemplate)
        }
    }

    // MARK: - Computed validation

    private var urlValidation: ExternalReleaseProvider.ValidationResult? {
        guard !urlTemplate.isEmpty else { return nil }
        return ExternalReleaseProvider.validate(urlTemplate: urlTemplate)
    }

    private var urlErrorMessage: String? {
        switch urlValidation {
        case .missingPlaceholder: return String(localized: "URL must contain a %s placeholder", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .multiplePlaceholders: return String(localized: "Only one %s placeholder is allowed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .invalidScheme: return String(localized: "URL must start with http:// or https://", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .malformed: return String(localized: "URL is malformed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .valid, nil: return nil
        }
    }

    private var previewText: String? {
        guard urlValidation == .valid else { return nil }
        let provider = ExternalReleaseProvider(name: name, urlTemplate: urlTemplate)
        return provider.buildURL(artistName: "Daft Punk", albumTitle: "Random Access Memories")?.absoluteString
    }

    private var canSave: Bool {
        ExternalReleaseProvider.validate(name: name) && urlValidation == .valid
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                SettingsTextFieldRow(title: "Name", systemImage: "textformat", color: .blue) {
                    TextField(String(localized: "Name", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $name)
                }
                if !name.isEmpty && !ExternalReleaseProvider.validate(name: name) {
                    Text(String(localized: "Name must be 1-50 characters", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                SettingsSectionHeader(verbatim: String(localized: "Provider Name", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            Section {
                SettingsTextFieldRow(title: "URL Template", systemImage: "link", color: .orange) {
                    TextField("https://example.com/search?q=%s", text: $urlTemplate, axis: .vertical)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }

                if let error = urlErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let preview = previewText {
                    Text(String(format: String(localized: "Example: %@", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), preview))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } header: {
                SettingsSectionHeader(verbatim: String(localized: "URL Template", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            } footer: {
                Text(String(localized: "Use %s as a placeholder — replaced by \"Artist Album\" when opening a release.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            if case .edit = mode, onDelete != nil {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label {
                            Text(String(localized: "Delete Provider", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "trash.fill", color: .red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(mode.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    let provider = ExternalReleaseProvider(
                        id: mode.existingID ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespaces),
                        urlTemplate: urlTemplate.trimmingCharacters(in: .whitespaces)
                    )
                    onSave(provider)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .confirmationDialog(
            String(format: String(localized: "Delete \"%@\"?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {}
        } message: {
            Text(String(localized: "This action cannot be undone.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }
}
