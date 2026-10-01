// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Compatibility wrapper — server credentials now live in `OnboardingServerSignInView`
/// as an integrated Apple Account–style onboarding step.
struct ServerFormView: View {
    @Bindable var viewModel: OnboardingViewModel
    var onConnected: (() -> Void)? = nil

    var body: some View {
        OnboardingServerSignInView(
            viewModel: viewModel,
            onConnected: { onConnected?() }
        )
    }
}

// MARK: - CustomHeaderRowView

struct CustomHeaderRowView: View {
    @Binding var key: String
    @Binding var value: String
    let onRemove: () -> Void

    @State private var isRevealed: Bool = false
    @State private var justCopied: Bool = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Header name", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. CF-Access-Client-Id", text: $key)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Text(String(localized: "Value", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, CassetteSpacing.xs)
            HStack(spacing: 0) {
                valueField
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(isRevealed ? CassetteColors.accent : CassetteColors.SemanticLabel.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: isRevealed)

                Button {
                    copyValueToClipboard()
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(value.isEmpty ? CassetteColors.SemanticLabel.tertiary : CassetteColors.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(value.isEmpty)
                .animation(.easeInOut(duration: 0.15), value: justCopied)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            if !key.isEmpty && !HeaderValidator.isValidName(key) {
                Text("Name '\(key)' contains characters not allowed by RFC 7230.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !value.isEmpty && !HeaderValidator.isValidValue(value) {
                Text("Value contains CR, LF, or NUL — not allowed in HTTP headers.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .labelsHidden()
        .padding(.vertical, CassetteSpacing.xs)
        .onDisappear {
            isRevealed = false
            copyFeedbackTask?.cancel()
        }
    }

    @ViewBuilder
    private var valueField: some View {
        if isRevealed {
            TextField(String(localized: "Value", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $value)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } else {
            SecureField(String(localized: "Value", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $value)
        }
    }

    private func copyValueToClipboard() {
        PlatformPasteboard.copy(value)
        copyFeedbackTask?.cancel()
        justCopied = true
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }
}
