// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Gapless playback preference.
///
/// The macOS Settings tab composes sections, so the preference is packaged as one; iOS surfaces
/// the same toggle as a plain row inside its grouped Playback card (see `PlaybackSettingsView`).
struct GaplessSettingsSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        let gapless = container?.gaplessSettings

        Section {
            Toggle(isOn: Binding(
                get: { gapless?.isEnabled ?? GaplessSettings.defaultEnabled },
                set: { newValue in
                    gapless?.isEnabled = newValue
                    Task { await container?.playerService.gaplessSettingsDidChange() }
                }
            )) {
                Label {
                    Text("Gapless Playback")
                } icon: {
                    SettingsIcon(systemImage: "arrow.triangle.merge", color: .indigo)
                }
            }
        } header: {
            SettingsSectionHeader("Gapless")
        } footer: {
            SettingsSectionFooter("Removes the silence between consecutive tracks.")
        }
    }
}
