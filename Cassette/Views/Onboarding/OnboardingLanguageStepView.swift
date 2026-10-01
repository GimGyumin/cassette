// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// First onboarding step: pick the app UI language before sign-in.
struct OnboardingLanguageStepView: View {
    let onContinue: () -> Void

    @State private var selection = AppUILanguage.preferredForPicker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SetupHeader(icon: "globe", title: String(localized: "Choose Your Language", bundle: AppUILanguage.localizationBundle(for: localeForSelection), locale: localeForSelection),
                                subtitle: String(localized: "You can change this later in Settings.", bundle: AppUILanguage.localizationBundle(for: localeForSelection), locale: localeForSelection))
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 8, trailing: 20))

                Section {
                    ForEach(AppUILanguage.allCases) { language in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                selection = language
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Text(language.displayName)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                if selection == language {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selection == language ? .isSelected : [])
                    }
                } header: {
                    Text(String(localized: "Language", bundle: AppUILanguage.localizationBundle(for: localeForSelection), locale: localeForSelection))
                }
            }
            .modifier(SetupFormStyle())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    AppUILanguage.select(selection)
                    onContinue()
                } label: {
                    Text(String(localized: "Continue", bundle: AppUILanguage.localizationBundle(for: localeForSelection), locale: localeForSelection))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SetupPrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .background { SetupBackground() }
            }
        }
        .environment(\.locale, localeForSelection)
    }

    private var localeForSelection: Locale {
        Locale(identifier: selection.rawValue)
    }

}
