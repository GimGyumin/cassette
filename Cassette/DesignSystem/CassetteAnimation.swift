// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Shared Apple-style motion tokens — prefer these over ad-hoc `easeInOut` / hard cuts.
enum CassetteAnimation {
    /// Theme / dominant-color settles (album, artist, player).
    static let theme = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// Sheets, overlays, centered cards (alert-like).
    static let present = Animation.spring(response: 0.42, dampingFraction: 0.72)

    /// Overlay / card dismiss.
    static let dismiss = Animation.spring(response: 0.28, dampingFraction: 0.92)

    /// Player surface morph (lyrics ↔ queue ↔ cover).
    static let surface = Animation.smooth(duration: 0.32)

    /// Scrubber / chrome show-hide.
    static let chrome = Animation.smooth(duration: 0.28)

    /// Compact interactive feedback (toggles, pills).
    static let interactive = Animation.snappy(duration: 0.22)

    /// Lyric line become-current emphasis (Apple Music–style soft scale/opacity).
    static let lyricLine = Animation.spring(response: 0.48, dampingFraction: 0.84)

    /// Word / cue fill within the active lyric line.
    static let lyricKaraoke = Animation.easeOut(duration: 0.16)

    /// Auto-scroll to the playing lyric — fast interactive spring avoids stacking unfinished
    /// animations that cause stutter when the active line changes rapidly (karaoke 60 Hz).
    static let lyricScroll = Animation.spring(response: 0.35, dampingFraction: 0.82)

    /// Dynamic Lyric Insertion — chorus block slides in under the translation line.
    /// Matches the Apple Music spec: 0.00s appear → translation shift @0.05s → settle @0.25s.
    static let lyricChorus = Animation.easeInOut(duration: 0.22)

    /// Reduce-motion fallbacks.
    static func theme(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : theme
    }

    static func present(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : present
    }

    static func dismiss(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeIn(duration: 0.15) : dismiss
    }
}
