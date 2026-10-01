// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct OnboardingCacheStepView: View {
    let onSkip: () -> Void
    let onContinue: () -> Void
    var totalSteps = 4

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepView(
            icon: "bolt.fill",
            title: String(localized: "Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "Keep recent tracks ready instantly, even on a slow connection.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            stepIndex: 0,
            totalSteps: totalSteps,
            onSkip: onSkip,
            onContinue: onContinue
        ) {
            if let settings = container?.cacheSettings {
                Section {
                    Picker(selection: Binding(
                        get: { settings.maxCacheMegabytes },
                        set: { settings.maxCacheMegabytes = $0 }
                    )) {
                        ForEach(CacheSettings.storageOptionsMB, id: \.self) { megabytes in
                            Text(Self.capacityLabel(megabytes)).tag(megabytes)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Storage Limit", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                Text(Self.capacityLabel(settings.maxCacheMegabytes))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .spring(duration: 0.25), value: settings.maxCacheMegabytes)
                            }
                        } icon: {
                            SettingsIcon(systemImage: "internaldrive.fill", color: .blue)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(String(localized: "Storage", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } footer: {
                    Text(String(localized: "Oldest track replaced when limit is reached", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.cacheFormat },
                        set: { settings.cacheFormat = $0 }
                    )) {
                        ForEach(CacheFormat.selectableCases) { format in
                            Text(format.title).tag(format)
                        }
                    } label: {
                        Label {
                            Text(String(localized: "Cache format", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "waveform", color: CassetteColors.accent)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { settings.cacheOverCellular },
                        set: { settings.cacheOverCellular = $0 }
                    )) {
                        Label {
                            Text(String(localized: "Use cellular data", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "antenna.radiowaves.left.and.right", color: .green)
                        }
                    }
                } header: {
                    Text(String(localized: "Network", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } footer: {
                    Text(String(localized: "Allow caching when not on Wi‑Fi", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
            }
        }
    }

    private static func capacityLabel(_ megabytes: Int) -> String {
        if megabytes < 1_024 {
            return "\(megabytes) MB"
        }
        return "\(megabytes / 1_024) GB"
    }
}
