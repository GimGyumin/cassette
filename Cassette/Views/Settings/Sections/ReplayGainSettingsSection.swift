// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct ReplayGainSettingsSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        let rg = container?.replayGainSettings

        Section {
            Toggle(isOn: Binding(
                get: { rg?.enabled ?? false },
                set: { newVal in
                    rg?.enabled = newVal
                    Task { await container?.playerService.replayGainSettingsDidChange() }
                }
            )) {
                Label {
                    Text(String(localized: "ReplayGain", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } icon: {
                    SettingsIcon(systemImage: "speaker.wave.3.fill", color: .pink)
                }
            }

            if rg?.enabled == true {
                Picker(selection: Binding(
                    get: { rg?.mode ?? .track },
                    set: { newVal in
                        rg?.mode = newVal
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    Text(String(localized: "Track", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(ReplayGainMode.track)
                    Text(String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)).tag(ReplayGainMode.album)
                } label: {
                    Label {
                        Text(String(localized: "Mode", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "rectangle.stack.fill", color: .purple)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text(String(localized: "Pre-amp", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } icon: {
                            SettingsIcon(systemImage: "slider.horizontal.3", color: .orange)
                        }
                        Spacer()
                        Text(preAmpLabel(rg?.preAmp ?? 0))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.body.weight(.medium))
                    }
                    Slider(
                        value: Binding(
                            get: { rg?.preAmp ?? 0 },
                            set: { newVal in
                                rg?.preAmp = newVal
                                Task { await container?.playerService.replayGainSettingsDidChange() }
                            }
                        ),
                        in: ReplayGainSettings.minPreAmp...ReplayGainSettings.maxPreAmp,
                        step: 0.5
                    )
                }

                Toggle(isOn: Binding(
                    get: { rg?.preventClipping ?? true },
                    set: { newVal in
                        rg?.preventClipping = newVal
                        Task { await container?.playerService.replayGainSettingsDidChange() }
                    }
                )) {
                    Label {
                        Text(String(localized: "Prevent clipping", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } icon: {
                        SettingsIcon(systemImage: "waveform.path.ecg", color: CassetteColors.accent)
                    }
                }
            }
        } header: {
            SettingsSectionHeader(verbatim: String(localized: "Volume", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } footer: {
            Text(String(localized: "ReplayGain levels volume across tracks so quieter and louder songs play more evenly.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private func preAmpLabel(_ dB: Double) -> String {
        let sign = dB > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dB)) dB"
    }
}
