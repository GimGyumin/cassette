// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// App information and support links, on their own screen instead of at the
/// bottom of the settings list.
struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildIdentifier: String {
        Bundle.main.infoDictionary?["CassetteBuildIdentifier"] as? String ?? "26A1001e"
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? "© 2026 Kyumin"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cassette")
                        .font(.title3.weight(.semibold))
                    Text(verbatim: "\(version) (\(buildIdentifier))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }

            Section {
                SettingsValueRow("Copyright", value: copyright)
                SettingsValueRow("License", value: "Mozilla Public License 2.0")

                DisclosureGroup {
                    SettingsValueRow("SwiftSonic", value: "MIT License — MathieuDubart")
                    HStack(alignment: .firstTextBaseline, spacing: CassetteSpacing.s) {
                        Text("AudioStreaming")
                        Spacer(minLength: CassetteSpacing.s)
                        Button("MIT License — dimitris-c") {
                            ExternalLinkOpener.open(CassetteURLs.audioStreaming)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                } label: {
                    Text("Open Source")
                }
            } header: {
                SettingsSectionHeader("Information")
            }

            Section {
                SettingsActionRow("View Source on GitHub") {
                    ExternalLinkOpener.open(CassetteURLs.cassette)
                }

                SettingsActionRow("Send Feedback") {
                    if let url = URL(string: "mailto:support@getcassette.app?subject=Feedback%20%2F%20Bug%20Report") {
                        ExternalLinkOpener.open(url)
                    }
                }

                VStack(spacing: 2) {
                    Text("Cassette is free, forever.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        ExternalLinkOpener.open(CassetteURLs.kofi)
                    } label: {
                        Image("kofiButton")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 140)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .accessibilityLabel(Text("Support Cassette on Ko-fi"))
                }
                .listRowBackground(Color.clear)
            } header: {
                SettingsSectionHeader("Support")
            } footer: {
                SettingsSectionFooter("Listening history, downloads, cache, and server passwords stay on this device.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("About"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
