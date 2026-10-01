// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct SetupBackground: View {
    var body: some View {
        #if os(iOS)
        Color(uiColor: .systemBackground).ignoresSafeArea()
        #else
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        #endif
    }
}

struct SetupHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.blue)
                .frame(height: 68)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 24)
    }
}

struct SetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? Color.blue.opacity(configuration.isPressed ? 0.75 : 1) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SetupFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background { SetupBackground() }
            .tint(.blue)
            #if os(iOS)
            .listSectionSpacing(18)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("")
    }
}

struct OnboardingStepView<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let stepIndex: Int
    let totalSteps: Int
    let onSkip: () -> Void
    let onContinue: () -> Void
    var skipTitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SetupHeader(icon: icon, title: title, subtitle: subtitle)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                content()
            }
            .modifier(SetupFormStyle())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    Text(String(localized: "Step \(stepIndex + 1) of \(totalSteps)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Continue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), action: onContinue)
                        .buttonStyle(SetupPrimaryButtonStyle())
                    Button(skipTitle ?? String(localized: "Set Up Later", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), action: onSkip)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(minHeight: 36)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .background { SetupBackground() }
            }
        }
    }
}
