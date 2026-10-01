// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Dynamic album page palette (background + WCAG text stops) derived from artwork.
/// Built on `AlbumColorAnalyzer` / `ArtworkPalette`, then refined for page / player / a11y modes.
struct DynamicAlbumPalette: Equatable, Sendable {
    enum Appearance: String, Sendable {
        case light
        case dark
        case increasedContrast
    }

    let background: Color
    let text1: Color
    let text2: Color
    let text3: Color
    let text4: Color
    let packedBackground: Int
    var appearance: Appearance = .dark

    var isLight: Bool { background.luminance > 0.55 }

    /// Convenience aliases matching the upgrade prompt naming.
    var textPrimary: Color { text1 }
    var textSecondary: Color { text2 }
    var textTertiary: Color { text3 }
    var textQuaternary: Color { text4 }

    static let clear = DynamicAlbumPalette(
        background: .clear,
        text1: .primary,
        text2: .secondary,
        text3: .secondary,
        text4: .secondary,
        packedBackground: 0,
        appearance: .dark
    )

    static func from(artworkPalette: ArtworkPalette, appearance: Appearance = .dark) -> DynamicAlbumPalette {
        adapt(
            background: artworkPalette.background,
            texts: (
                artworkPalette.text1,
                artworkPalette.text2,
                artworkPalette.text3,
                artworkPalette.text4
            ),
            packed: artworkPalette.packedBackground,
            appearance: appearance
        )
    }

    /// Album / playlist page: refine the analyzer background through CoverColorRefiner.
    static func forAlbumPage(dominantColor: Color, appearance: Appearance = .dark) -> DynamicAlbumPalette {
        guard dominantColor != .clear else { return .clear }
        let refined = CoverColorRefiner.atmosphere(from: dominantColor)
        let isLightPage = refined.isLight
        let texts = isLightPage
            ? (
                Color(red: 0.08, green: 0.08, blue: 0.10),
                Color(red: 0.18, green: 0.18, blue: 0.20).opacity(0.92),
                Color(red: 0.28, green: 0.28, blue: 0.30).opacity(0.78),
                Color(red: 0.35, green: 0.35, blue: 0.38).opacity(0.62)
            )
            : (
                Color(red: 0.98, green: 0.97, blue: 0.95),
                Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.86),
                Color(red: 0.94, green: 0.93, blue: 0.90).opacity(0.68),
                Color(red: 0.92, green: 0.91, blue: 0.88).opacity(0.50)
            )
        return adapt(
            background: refined.pageColor,
            texts: texts,
            packed: 0,
            appearance: appearance
        )
    }

    /// Now Playing: always-dark wash with light chrome text.
    static func forPlayer(dominantColor: Color, appearance: Appearance = .dark) -> DynamicAlbumPalette {
        guard dominantColor != .clear else { return .clear }
        let refined = CoverColorRefiner.playerAtmosphere(from: dominantColor)
        let texts = (
            Color(red: 0.98, green: 0.97, blue: 0.95),
            Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.86),
            Color(red: 0.94, green: 0.93, blue: 0.90).opacity(0.68),
            Color(red: 0.92, green: 0.91, blue: 0.88).opacity(0.50)
        )
        return adapt(
            background: refined.pageColor,
            texts: texts,
            packed: 0,
            appearance: appearance
        )
    }

    /// Soften / darken / boost contrast without changing the analyzer’s hue intent.
    private static func adapt(
        background: Color,
        texts: (Color, Color, Color, Color),
        packed: Int,
        appearance: Appearance
    ) -> DynamicAlbumPalette {
        guard let hsb = hsb(background) else {
            return DynamicAlbumPalette(
                background: background,
                text1: texts.0,
                text2: texts.1,
                text3: texts.2,
                text4: texts.3,
                packedBackground: packed,
                appearance: appearance
            )
        }

        let hue = hsb.h
        var sat = hsb.s
        var bright = hsb.b
        var t1 = texts.0
        var t2 = texts.1
        var t3 = texts.2
        var t4 = texts.3

        switch appearance {
        case .light:
            // Pastel wash for light-mode surfaces. Gently brighten the seed while capping at
            // 0.88 — bright enough to feel like a light page, but always with a visible tint
            // distinct from white (the old 0.94 ceiling produced a blank-sheet look).
            sat = min(sat * 0.75, 0.45)
            bright = min(max(bright * 1.08, 0.72), 0.88)
            // Only force dark ink when the adapted page is actually light.
            if bright > 0.60 {
                t1 = Color(red: 0.08, green: 0.08, blue: 0.10)
                t2 = Color(red: 0.18, green: 0.18, blue: 0.20).opacity(0.90)
                t3 = Color(red: 0.28, green: 0.28, blue: 0.30).opacity(0.72)
                t4 = Color(red: 0.35, green: 0.35, blue: 0.38).opacity(0.55)
            }
        case .dark:
            // Dark-mode wash only when the seed is still light; already-dark player/page tones stay.
            if bright > 0.55 || relativeLuminanceGuess(bright: bright, sat: sat) > 0.55 {
                sat = min(max(sat * 0.85, 0.04), 0.55)
                bright = min(max(bright * 0.42, 0.18), 0.46)
            } else {
                sat = min(max(sat * 0.92, sat * 0.85), 0.78)
                bright = min(max(bright, 0.12), 0.52)
            }
        case .increasedContrast:
            if bright > 0.55 {
                bright = min(bright + 0.08, 0.97)
                sat = min(sat * 0.7, 0.35)
                t1 = .black
                t2 = Color.black.opacity(0.78)
                t3 = Color.black.opacity(0.60)
                t4 = Color.black.opacity(0.45)
            } else {
                bright = max(bright - 0.08, 0.08)
                sat = min(sat * 0.85, 0.55)
                t1 = Color(red: 1, green: 1, blue: 1)
                t2 = Color.white.opacity(0.88)
                t3 = Color.white.opacity(0.68)
                t4 = Color.white.opacity(0.48)
            }
        }

        let bg = Color(
            hue: hue.truncatingRemainder(dividingBy: 1),
            saturation: min(max(sat, 0), 1),
            brightness: min(max(bright, 0), 1)
        )
        return DynamicAlbumPalette(
            background: bg,
            text1: t1,
            text2: t2,
            text3: t3,
            text4: t4,
            packedBackground: packed,
            appearance: appearance
        )
    }

    private static func relativeLuminanceGuess(bright: Double, sat: Double) -> Double {
        // Cheap stand-in: high brightness + low sat ≈ light page.
        bright * (1.0 - sat * 0.35)
    }

    private static func hsb(_ color: Color) -> (h: Double, s: Double, b: Double)? {
        #if canImport(UIKit)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return (Double(h), Double(s), Double(b))
        #elseif canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
