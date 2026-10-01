// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Album / cover detail atmosphere: raw artwork identity → appearance-specific palette
/// (Apple Music direction).
///
/// Internally the analysis is separated from the appearance: a `RawArtworkColorAnalysis`
/// is transformed independently into Light / Dark / player palettes via
/// `ArtworkColorTransformer`, so switching between Light and Dark never re-runs artwork
/// analysis — only the palette is rebuilt.
struct AlbumAtmosphere: Equatable, Sendable {
    /// Raw artwork identity seed (`.clear` = unresolved).
    let sourceColor: Color
    /// The page base tone (what the flat album page fills with).
    let pageColor: Color
    /// Elevated surface tone for toolbar / shelves / floating controls.
    let elevated: Color
    let gradientTop: Color
    let gradientMid: Color
    let gradientBottom: Color
    /// Semantic text hierarchy (primary → quaternary).
    let text1: Color
    let text2: Color
    let text3: Color
    let text4: Color

    var isThemed: Bool { sourceColor != .clear }
    var isLight: Bool { isThemed && !CassetteColors.prefersLightControl(on: pageColor) }

    var preferredColorScheme: ColorScheme? {
        guard isThemed else { return nil }
        return isLight ? .light : .dark
    }

    /// All visible text & glyph ink is PURE white / black, decided only by the page
    /// luminance — no gray tiers, no cover tint. (Apple Music 26.4 simplification.)
    var contentColor: Color { isThemed ? (isLight ? .black : .white) : .primary }
    var secondaryContentColor: Color { contentColor }
    var tertiaryContentColor: Color { contentColor }
    var quaternaryContentColor: Color { contentColor }

    /// Shelf fill for “More by” / recessed sections — uses the elevated surface tone.
    var recessedSectionColor: Color {
        guard isThemed else {
            #if canImport(UIKit)
            return Color(UIColor.secondarySystemBackground)
            #elseif canImport(AppKit)
            return Color(NSColor.controlBackgroundColor)
            #else
            return Color.primary.opacity(0.06)
            #endif
        }
        return elevated
    }

    var controlGlassTint: Color {
        guard isThemed else { return Color.primary.opacity(0.18) }
        return isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.28)
    }

    var coverShadowColor: Color {
        guard isThemed else { return .black.opacity(0.35) }
        return isLight ? Color.black.opacity(0.30) : Color.black.opacity(0.45)
    }

    var heroTheme: PlaylistTheme {
        PlaylistTheme(dominantColor: isThemed ? pageColor : .clear)
    }

    /// Back-compat aliases.
    var top: Color { gradientTop }
    var mid: Color { gradientMid }
    var bottom: Color { gradientBottom }

    // MARK: - Factory (analysis-based, appearance-independent upstream)

    static func from(
        analysis: RawArtworkColorAnalysis,
        appearance: AlbumAppearance
    ) -> AlbumAtmosphere {
        // Content-first (Apple Music 26.4): the page background is the artwork's own color
        // — system Light/Dark appearance does NOT transform it. Only text contrast is
        // adjusted by the increased-contrast accessibility flag.
        let palette = ArtworkColorTransformer.page(from: analysis, increasedContrast: appearance.increaseContrast)

        return AlbumAtmosphere(
            sourceColor: analysis.backgroundCandidate,
            pageColor: palette.base,
            elevated: palette.elevated,
            gradientTop: palette.top,
            gradientMid: palette.mid,
            gradientBottom: palette.bottom,
            text1: palette.text1,
            text2: palette.text2,
            text3: palette.text3,
            text4: palette.text4
        )
    }

    static func from(
        dominantColor: Color,
        colorScheme: ColorScheme,
        increaseContrast: Bool
    ) -> AlbumAtmosphere {
        guard dominantColor != .clear else { return .unthemed }
        // `colorScheme` is intentionally unused for the background — content decides color.
        return from(
            analysis: RawArtworkColorAnalysis(color: dominantColor),
            appearance: AlbumAppearance(isLight: false, increaseContrast: increaseContrast)
        )
    }

    /// Legacy bridge for callers using `DynamicAlbumPalette.Appearance`. All appearances
    /// map to the same appearance-independent page palette.
    static func from(
        dominantColor: Color,
        appearance: DynamicAlbumPalette.Appearance = .dark
    ) -> AlbumAtmosphere {
        guard dominantColor != .clear else { return .unthemed }
        let analysis = RawArtworkColorAnalysis(color: dominantColor)
        let increaseContrast: Bool
        switch appearance {
        case .light, .dark:
            increaseContrast = false
        case .increasedContrast:
            increaseContrast = true
        }
        return from(
            analysis: analysis,
            appearance: AlbumAppearance(isLight: false, increaseContrast: increaseContrast)
        )
    }

    static func from(
        palette: ArtworkPalette,
        appearance: DynamicAlbumPalette.Appearance = .dark
    ) -> AlbumAtmosphere {
        from(dominantColor: palette.background, appearance: appearance)
    }

    /// Resolve the legacy flattened `DynamicAlbumPalette.Appearance` from the system
    /// color scheme + Increase Contrast accessibility flag.
    static func appearance(
        colorScheme: ColorScheme,
        increaseContrast: Bool
    ) -> DynamicAlbumPalette.Appearance {
        if increaseContrast { return .increasedContrast }
        return colorScheme == .light ? .light : .dark
    }

    private static let unthemed = AlbumAtmosphere(
        sourceColor: .clear,
        pageColor: .clear,
        elevated: .clear,
        gradientTop: .clear,
        gradientMid: .clear,
        gradientBottom: .clear,
        text1: .primary,
        text2: .secondary,
        text3: .secondary,
        text4: .secondary
    )
}

/// The appearance context used to build a palette. Unlike the legacy flattened
/// `DynamicAlbumPalette.Appearance`, it preserves BOTH the light/dark axis and the
/// increased-contrast flag, so high-contrast light and high-contrast dark remain distinct.
struct AlbumAppearance: Equatable, Sendable {
    let isLight: Bool
    let increaseContrast: Bool

    static func from(colorScheme: ColorScheme, increaseContrast: Bool) -> AlbumAppearance {
        AlbumAppearance(isLight: colorScheme == .light, increaseContrast: increaseContrast)
    }
}
