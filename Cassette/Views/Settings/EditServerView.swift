// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct EditServerView: View {
    @Bindable var viewModel: EditServerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDiscardAlert = false
    @State private var isPasswordRevealed = false

    var body: some View {
        Group {
            if viewModel.isLoadingCredentials {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle("Server Configuration")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(viewModel.hasUnsavedChanges)
        .toolbar { toolbar }
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    if viewModel.hasUnsavedChanges {
                        showDiscardAlert = true
                    } else {
                        dismiss()
                    }
                }
            }
        }
        #endif
        .alert("Discard Changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes will be lost.")
        }
        .task {
            await viewModel.loadCredentials()
        }
    }

    // MARK: - Toolbar (iOS only)

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if viewModel.hasUnsavedChanges {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    showDiscardAlert = true
                } label: {
                    Image(systemName: "chevron.backward")
                        .fontWeight(.semibold)
                }
            }
        }
    }
    #endif

    // MARK: - Form

    private var form: some View {
        Form {
            serverSection
            credentialsSection
            errorSection
            customHeadersSection
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveButton
        }
    }

    private var saveButton: some View {
        Button {
            // Resign the keyboard first so iOS Password AutoFill's "Save Password"
            // sheet doesn't stack on top of this form and freeze the UI.
            #if os(iOS)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            #endif
            Task {
                await viewModel.save()
                if viewModel.connectionError == nil,
                   viewModel.saveError == nil,
                   !viewModel.hasUnsavedChanges {
                    dismiss()
                }
            }
        } label: {
            if viewModel.isSaving {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                Label("Save Changes", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .cassetteAccentGlassButton(disabled: !viewModel.canSave || viewModel.isSaving)
        .controlSize(.large)
        .disabled(!viewModel.canSave || viewModel.isSaving)
        .padding(.horizontal)
        .padding(.vertical, CassetteSpacing.m)
        .background(.regularMaterial)
    }

    private var serverSection: some View {
        Section("Server") {
            SettingsTextFieldRow(title: "Address", systemImage: "network", color: .blue) {
                TextField("https://music.example.com", text: $viewModel.serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            }
            invalidURLHint
            httpWarning
        }
    }

    private var credentialsSection: some View {
        Section("Credentials") {
            SettingsTextFieldRow(title: "Username", systemImage: "person.fill", color: .blue) {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            LabeledContent {
                HStack(spacing: 8) {
                    passwordField
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    Button {
                        isPasswordRevealed.toggle()
                    } label: {
                        Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordRevealed ? "Hide password" : "Show password")
                }
            } label: {
                SettingsRowLabel(title: "Password", systemImage: "key.fill", color: .orange)
            }
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        if isPasswordRevealed {
            TextField("Password", text: $viewModel.password)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
        }
    }

    @ViewBuilder
    private var httpWarning: some View {
        if viewModel.isHTTP {
            Label("Unencrypted connection — make sure you are on a trusted network.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var invalidURLHint: some View {
        if case .invalidURL = viewModel.connectionError {
            Text("Enter a valid URL, including http:// or https://")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.connectionError, error != .invalidURL {
            Section {
                ConnectionErrorView(error: error)
                    .padding(.vertical, CassetteSpacing.xs)
            }
        }
        if let error = viewModel.saveError {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var customHeadersSection: some View {
        Section {
            DisclosureGroup {
                ForEach($viewModel.customHeaders) { $header in
                    CustomHeaderRowView(
                        key: $header.key,
                        value: $header.value,
                        onRemove: { viewModel.removeCustomHeader(id: header.id) }
                    )
                }
                Button(action: viewModel.addCustomHeader) {
                    Label("Add Header", systemImage: "plus")
                }
            } label: {
                SettingsRowLabel(title: "Custom Headers", systemImage: "curlybraces", color: .gray)
            }
        } footer: {
            Text("Optional headers sent with every request — useful for Cloudflare Access or other reverse-proxy authentication.")
                .font(.footnote)
        }
    }

}

// MARK: - Navigation destination wrapper

/// Owns the ViewModel lifetime so it is created exactly once per navigation push.
struct EditServerDestinationView: View {
    let server: ServerSnapshot
    let serverService: any ServerServiceProtocol
    @State private var viewModel: EditServerViewModel

    init(server: ServerSnapshot, serverService: any ServerServiceProtocol) {
        self.server = server
        self.serverService = serverService
        self._viewModel = State(initialValue: EditServerViewModel(server: server, serverService: serverService))
    }

    var body: some View {
        EditServerView(viewModel: viewModel)
    }
}
