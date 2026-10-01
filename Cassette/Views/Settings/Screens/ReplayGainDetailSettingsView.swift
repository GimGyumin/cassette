// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension ReplayGainMode: SettingsChoiceItem {
    var choiceTitle: String {
        self == .album
            ? String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : String(localized: "Track", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}

/// Technical ReplayGain controls, reached from Playback ▸ Volume Leveling
/// Options so the playback screen itself stays a plain list of rows.
struct ReplayGainDetailSettingsView: View {
    @Environment(\.appContainer) private var container

    private var replayGain: ReplayGainSettings? { container?.replayGainSettings }

    var body: some View {
        Form {
            Section {
                SettingsNavigationRow("ReplayGain Mode", value: modeTitle) {
                    SettingsChoiceList(
                        navigationTitle: "ReplayGain Mode",
                        items: ReplayGainMode.allCases,
                        selection: Binding(
                            get: { replayGain?.mode ?? .track },
                            set: { newValue in
                                replayGain?.mode = newValue
                                Task { await container?.playerService.replayGainSettingsDidChange() }
                            }
                        )
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pre-amp")
                        Spacer(minLength: CassetteSpacing.s)
                        Text(preAmpLabel(replayGain?.preAmp ?? 0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { replayGain?.preAmp ?? 0 },
                            set: { newValue in
                                replayGain?.preAmp = newValue
                                Task { await container?.playerService.replayGainSettingsDidChange() }
                            }
                        ),
                        in: ReplayGainSettings.minPreAmp...ReplayGainSettings.maxPreAmp,
                        step: 0.5
                    )
                    .accessibilityLabel(Text("Pre-amp"))
                }

                Toggle(isOn: Binding(
                    get: { replayGain?.preventClipping ?? true },
                    set: { newValue in
                        replayGain?.preventClipping = newValue
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    SettingsRowTitle("Prevent Clipping")
                }
            } header: {
                SettingsSectionHeader("ReplayGain")
            } footer: {
                SettingsSectionFooter("ReplayGain levels volume across tracks so quieter and louder songs play more evenly.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Volume Leveling"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var modeTitle: String {
        (replayGain?.mode ?? .track).choiceTitle
    }

    private func preAmpLabel(_ dB: Double) -> String {
        let sign = dB > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dB)) dB"
    }
}

/// Crossfade detail screen: the slider lives here instead of the playback
/// screen so the main list stays plain.
struct CrossfadeSettingsView: View {
    var body: some View {
        Form {
            CrossfadeSettingsSection()
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Crossfade"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
