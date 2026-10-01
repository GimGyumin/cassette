// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents

/// Pre-registers Cassette's app-specific phrases with Siri.
///
/// Audio-schema actions (`playAudio`, `updateAudioAffinity`, …) are handled by
/// the system via the schemas themselves — they don't need phrases here. Only
/// Cassette-unique actions (playback transport) get a shortcut.
struct CassetteAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Play or pause in \(.applicationName)",
                "Toggle playback in \(.applicationName)"
            ],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.fill"
        )
    }
}
