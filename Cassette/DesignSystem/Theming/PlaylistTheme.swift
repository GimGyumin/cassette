// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Cross-platform colour palette for the themed detail surfaces (Apple-Music direction) — reused across the
/// playlist / album / artist heroes and BOTH platforms (deliberately no `#if os`). It wraps a single resolved
/// `dominantColor` and produces the adaptive foreground palette; `PlaylistThemedBackground` consumes the same
/// theme for the blended background.
struct PlaylistTheme: Equatable, Sendable {
    /// Base theme color. `.clear` = not resolved yet → system-adaptive fallback (no blend).
    let dominantColor: Color

    init(dominantColor: Color) {
        self.dominantColor = dominantColor
    }

    var isThemed: Bool { dominantColor != .clear }
    var isLight: Bool { isThemed && !CassetteColors.prefersLightControl(on: dominantColor) }

    /// Force Liquid Glass / system chrome to match cover luminance (not the global dark/light setting).
    /// Without this, dark-mode glass controls render as muddy gray over a dark themed hero.
    var preferredColorScheme: ColorScheme? {
        guard isThemed else { return nil }
        return isLight ? .light : .dark
    }

    /// Frost for circular glass controls (shuffle / download) over the hero.
    var controlGlassTint: Color {
        guard isThemed else { return Color.primary.opacity(0.18) }
        // Stronger frost than 0.14/0.18 — weak white tint collapses to system gray under Liquid Glass.
        return isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.28)
    }

    // Adaptive foreground over the themed background. `isLight` uses the app-wide PERCEIVED (BT.601) luminance
    // (`Color.luminance > 0.6`) — the same light/dark convention as the full player, and the Apple-Music-correct
    // bias toward white text (dark text only on clearly light covers). System-adaptive (`.primary`/`.secondary`)
    // until the theme color resolves.
    var contentColor: Color { isThemed ? (isLight ? .black : .white) : .primary }
    var secondaryContentColor: Color {
        // 0.78 keeps artist/duration readable on saturated cover themes; 0.7 + extra
        // row opacities was washing track lists out.
        isThemed ? (isLight ? Color.black.opacity(0.78) : Color.white.opacity(0.78)) : .secondary
    }
}
