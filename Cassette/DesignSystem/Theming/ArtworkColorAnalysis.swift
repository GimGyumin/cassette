// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Artwork classification

/// Artwork identity buckets used to steer appearance-specific remapping.
///
/// These are *project heuristics* — Apple publishes `backgroundColor` / semantic text
/// colors via artwork metadata, but for locally-analyzed artwork we derive a class from a
/// perceptual model so Light and Dark palettes can be produced independently.
nonisolated enum ArtworkColorClass: String, Equatable, Sendable {
    case black
    case white
    case neutral
    case silver
    case gold
    case pastel
    case saturated
    case portrait
    case multiColor
    case gradient
    case photographic
}

// MARK: - Raw analysis

/// Appearance-independent artifact of analyzing one artwork.
///
/// This is the "raw identity" layer. It is deliberately separated from the appearance
/// palettes so Light / Dark / increased-contrast surfaces can be rebuilt without re-running
/// image analysis.
nonisolated struct RawArtworkColorAnalysis: Equatable, Sendable {
    /// The single most representative color (backgroundCandidate is the page seed).
    let primaryColor: Color
    /// Second-most representative color (when a clear secondary exists).
    let secondaryColor: Color
    /// A neutralized version of the primary (used to ground busy scenes).
    let neutralColor: Color
    /// The color that should seed page backgrounds.
    let backgroundCandidate: Color

    /// 0…1 — how much the classification / candidate should be trusted.
    var confidence: Double = 1.0
    /// WCAG relative luminance of `backgroundCandidate`.
    var luminance: Double = 0.0
    /// OKLab chroma (perceptual colorfulness) of `backgroundCandidate`.
    var chroma: Double = 0.0
    /// HSV saturation of `backgroundCandidate`.
    var saturation: Double = 0.0

    var isMostlyBlack: Bool = false
    var isMostlyWhite: Bool = false
    var isNeutral: Bool = false
    var isPastel: Bool = false
    var isMetallic: Bool = false
    var isMultiColor: Bool = false

    /// 0…1 — how much the border represents the true background (vs frame/logo clutter).
    var borderConfidence: Double = 0.0
    /// 0…1 — how much a skin tone influenced the candidate (penalty, not exclusion).
    var skinToneInfluence: Double = 0.0
    /// True when the border is predominantly white/light — a strong signal that the page
    /// should stay a bright light theme even if the center subject is dark (e.g. "Bad").
    var borderIsLight: Bool = false

    var colorClass: ArtworkColorClass = .neutral
    var packedBackground: Int = 0

    /// Minimal analysis from a single seed color (back-compat path where only the dominant
    /// color was memoized). Derives the same identity flags from perception of that color.
    init(color: Color) {
        let rgb = ArtworkColorMath.srgb(color) ?? (0, 0, 0)
        let l = ArtworkColorMath.relativeLuminance(rgb.0, rgb.1, rgb.2)
        let hsb = ArtworkColorMath.hsb(color) ?? (0, 0, 0)
        let okl = ArtworkColorMath.oklab(rgb.0, rgb.1, rgb.2)
        let chroma = hypot(okl.a, okl.b)

        primaryColor = color
        secondaryColor = color
        neutralColor = ArtworkColorMath.neutralized(color)
        backgroundCandidate = color
        luminance = l
        self.chroma = chroma
        saturation = hsb.s
        // Low luminance alone does not mean black: saturated blue/purple can have a very
        // small WCAG luminance while still carrying strong visible color identity.
        isMostlyBlack = hsb.b < 0.06 || (l < 0.04 && hsb.s < 0.20)
        isMostlyWhite = hsb.s < 0.12 && l >= 0.90
        isNeutral = hsb.s < 0.14
        isPastel = hsb.s < 0.35 && hsb.b >= 0.45 && l >= 0.42
        isMetallic = ArtworkColorMath.isMetallic(hsb: hsb, luminance: l, chroma: chroma)
        isMultiColor = false
        borderConfidence = 1.0
        skinToneInfluence = ArtworkColorMath.skinInfluence(hsb: hsb)
        borderIsLight = false
        colorClass = ArtworkColorAnalysisClassifier.classify(
            hsb: hsb, luminance: l, chroma: chroma, skin: skinToneInfluence
        )
        packedBackground = ArtworkColorMath.packed(rgb)
    }

    init(
        primaryColor: Color,
        secondaryColor: Color,
        neutralColor: Color,
        backgroundCandidate: Color,
        confidence: Double,
        luminance: Double,
        chroma: Double,
        saturation: Double,
        isMostlyBlack: Bool,
        isMostlyWhite: Bool,
        isNeutral: Bool,
        isPastel: Bool,
        isMetallic: Bool,
        isMultiColor: Bool,
        borderConfidence: Double,
        skinToneInfluence: Double,
        borderIsLight: Bool = false,
        colorClass: ArtworkColorClass,
        packedBackground: Int
    ) {
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.neutralColor = neutralColor
        self.backgroundCandidate = backgroundCandidate
        self.confidence = confidence
        self.luminance = luminance
        self.chroma = chroma
        self.saturation = saturation
        self.isMostlyBlack = isMostlyBlack
        self.isMostlyWhite = isMostlyWhite
        self.isNeutral = isNeutral
        self.isPastel = isPastel
        self.isMetallic = isMetallic
        self.isMultiColor = isMultiColor
        self.borderConfidence = borderConfidence
        self.skinToneInfluence = skinToneInfluence
        self.borderIsLight = borderIsLight
        self.colorClass = colorClass
        self.packedBackground = packedBackground
    }
}

// MARK: - Appearance palette

/// Appearance-specific output derived from a `RawArtworkColorAnalysis`.
///
/// Light and Dark palettes are computed by separate transforms — never a simple inversion
/// or `.opacity(...)` of the other.
nonisolated struct AppearanceColorPalette: Equatable, Sendable {
    let base: Color
    let elevated: Color
    let top: Color
    let mid: Color
    let bottom: Color
    let text1: Color
    let text2: Color
    let text3: Color
    let text4: Color
    let isLight: Bool
}

// MARK: - Tuning

/// Centralized visual tuning for the Dark/Light color transforms.
///
/// These are **project tuning parameters**, not Apple-endorsed constants. They exist so
/// the Dark Mode "darken, don't neutralize" balance can be adjusted against real Apple
/// Music screenshots without editing transform logic.
nonisolated enum ArtworkColorTuning {
    /// Dark Mode keeps this fraction of the raw saturation (chroma) for chromatic art.
    static let darkChromaRetention: Double = 0.80
    /// Minimum saturation after dark remap, so a hue never fully collapses to gray.
    /// Raised so dark backgrounds keep Apple Music–level chroma (S ≈ 44–50%).
    static let darkSaturationFloor: Double = 0.44
    /// Luminance (HSV value) multiplier applied to the raw brightness in Dark Mode.
    static let darkLuminanceScale: Double = 0.30

    /// Dark base brightness band (HSV value) per artwork class.
    static func darkBrightness(for cls: ArtworkColorClass) -> (floor: Double, ceiling: Double) {
        switch cls {
        case .multiColor, .gradient, .photographic, .portrait:
            return (0.10, 0.18)
        case .saturated, .pastel, .gold:
            return (0.16, 0.28)
        default:
            return (0.12, 0.24)
        }
    }

    /// Light-mode saturation cap to keep hues present without a neon look.
    static let lightSaturationCap: Double = 0.55

    // MARK: Light Mode

    /// Below this saturation a color is treated as an achromatic neutral in Light Mode.
    static let lightNeutralSaturationCutoff: Double = 0.08
    /// Light Mode keeps this fraction of raw saturation for chromatic art.
    static let lightChromaticChromaRetention: Double = 0.65
    /// Blue / purple / indigo floor — prevents gray-lavender washout (Immortal).
    static let lightCoolHueSaturationFloor: Double = 0.22
    /// Generic chromatic floor for red / green / cyan / pink, etc.
    static let lightGenericSaturationFloor: Double = 0.18

    /// True for blue / purple / indigo (200°–290°) which need extra chroma protection.
    static func isCoolHue(_ h: Double) -> Bool {
        let degrees = h * 360.0
        return degrees >= 200.0 && degrees <= 290.0
    }

    // MARK: Dark-adaptive Light

    /// In Light Mode, a deep chromatic artwork (e.g. deep blue/purple) keeps a dark
    /// atmosphere instead of being lightened. Thresholds define "deep".
    static let darkAdaptiveBrightnessThreshold: Double = 0.45
    static let darkAdaptiveSaturationThreshold: Double = 0.20

    /// Pure black / dark-neutral artwork (e.g. Thriller) stays near-black in Light Mode.
    static let darkNeutralBrightnessThreshold: Double = 0.20
    static let darkNeutralSaturationThreshold: Double = 0.15

    /// Mid-tone achromatic artwork (metallic textures like "Thriller 40") reads heavy, not
    /// pale, in Light Mode — remapped to a dark gray with white text.
    static let darkAdaptiveMidToneSaturationMax: Double = 0.12
    static let darkAdaptiveMidToneBrightnessFloor: Double = 0.20
    static let darkAdaptiveMidToneBrightnessCeiling: Double = 0.52
}

// MARK: - Transformer

/// Produces Apple-Music-style Light / Dark / player palettes from raw artwork identity.
///
/// Apple's Dark Mode is best described as "lights dimmed", not color inversion. Each
/// appearance remaps hue/luminance/chroma independently with distinct targets.
nonisolated enum ArtworkColorTransformer {

    // MARK: Page — appearance-independent (Apple Music 26.4 style)

    /// The album/playlist page background is the artwork's own representative color,
    /// **unchanged by Light/Dark system appearance**. Only the foreground (black/white,
    /// 4 contrast tiers) is derived from the background's actual luminance — "content
    /// decides the background, contrast decides the text".
    ///
    /// Analysis runs once upstream (`RawArtworkColorAnalysis`); this transform is a cheap
    /// projection, never a re-analysis.
    static func page(from analysis: RawArtworkColorAnalysis, increasedContrast: Bool = false) -> AppearanceColorPalette {
        let base = analysis.backgroundCandidate
        let isLight = base != .clear
            && (ArtworkColorMath.srgb(base).map { ArtworkColorMath.relativeLuminance($0.0, $0.1, $0.2) } ?? 0) >= sqrt(0.0525) - 0.05

        // Foreground is neutral black/white, NOT the artwork hue — matching the 26.4
        // simplification to contrast-driven text. Hue identity lives only in the background.
        let texts = ArtworkColorMath.semanticText(
            on: base,
            isLight: isLight,
            increasedContrast: increasedContrast
        )

        // Ambient gradient stays in the SAME hue family as the artwork background, but is
        // a soft vertical depth (top → bottom), not a light/dark transform of the base.
        let hsb = ArtworkColorMath.hsb(base) ?? (0, 0, 0)
        let top = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s, 0.80), b: min(hsb.b + 0.03, 1))
        let mid = base
        let bottom = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s, 0.80), b: max(hsb.b - 0.04, 0))
        let elevated = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.6, 0.40), b: min(hsb.b + 0.04, 1))

        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: mid, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3,
            isLight: isLight
        )
    }

    // MARK: Page — Light

    static func lightPage(from analysis: RawArtworkColorAnalysis, increasedContrast: Bool = false) -> AppearanceColorPalette {
        var hsb = ArtworkColorMath.hsb(analysis.backgroundCandidate) ?? (0, 0, 0)
        let rawSat = hsb.s
        let rawBright = hsb.b
        let hue = hsb.h

        // Identity-first: deep / black artwork keeps a dark atmosphere even in Light Mode,
        // flipping only the semantic text/controls to light. (Thriller, Immortal.)
        // A light border overrides these — "Bad" (white jacket, dark subject) must stay light.
        let isDarkNeutral = !analysis.borderIsLight
            && (analysis.isMostlyBlack
                || (rawBright < ArtworkColorTuning.darkNeutralBrightnessThreshold
                    && rawSat < ArtworkColorTuning.darkNeutralSaturationThreshold))
        let isMidToneNeutral = !analysis.borderIsLight
            && rawSat < ArtworkColorTuning.darkAdaptiveMidToneSaturationMax
            && rawBright >= ArtworkColorTuning.darkAdaptiveMidToneBrightnessFloor
            && rawBright < ArtworkColorTuning.darkAdaptiveMidToneBrightnessCeiling
        let isDeepChromatic = !analysis.borderIsLight
            && ArtworkColorTuning.isCoolHue(hue)
            && rawBright < ArtworkColorTuning.darkAdaptiveBrightnessThreshold
            && rawSat > ArtworkColorTuning.darkAdaptiveSaturationThreshold

        if isDarkNeutral {
            return darkNeutralLightPalette(increasedContrast: increasedContrast)
        }
        if isMidToneNeutral {
            return midToneNeutralLightPalette(rawBright: rawBright, increasedContrast: increasedContrast)
        }
        if isDeepChromatic {
            return deepChromaticLightPalette(hue: hue, rawSat: rawSat, rawBright: rawBright, increasedContrast: increasedContrast)
        }

        if analysis.colorClass == .black {
            // Black art on a light page should not paint a heavy black page; use soft charcoal.
            hsb.s = min(rawSat, 0.08)
            hsb.b = min(max(rawBright, 0.78), 0.88)
        } else if analysis.colorClass == .white {
            hsb.s = 0.02
            hsb.b = 0.975
        } else if analysis.colorClass == .silver || rawSat <= ArtworkColorTuning.lightNeutralSaturationCutoff {
            // Only genuine neutrals stay achromatic. A faint cool cast is kept, never
            // force-mapped to blue/purple.
            hsb.h = rawSat < 0.05 ? 0.58 : hue
            hsb.s = min(rawSat, 0.06)
            hsb.b = min(max(rawBright, 0.82), 0.92)
        } else if ArtworkColorTuning.isCoolHue(hue) {
            // Blue / purple / indigo: extra chroma floor against gray-lavender washout (Immortal).
            hsb.s = min(max(rawSat * ArtworkColorTuning.lightChromaticChromaRetention, ArtworkColorTuning.lightCoolHueSaturationFloor), ArtworkColorTuning.lightSaturationCap)
            hsb.b = min(max(rawBright, 0.82), 0.90)
        } else {
            // Red / orange / yellow / green / cyan / pink / portrait / multi-color, etc.
            hsb.s = min(max(rawSat * ArtworkColorTuning.lightChromaticChromaRetention, ArtworkColorTuning.lightGenericSaturationFloor), ArtworkColorTuning.lightSaturationCap)
            hsb.b = min(max(rawBright, 0.85), 0.94)
        }

        let base = ArtworkColorMath.color(h: hsb.h, s: hsb.s, b: hsb.b)

        // Light gradient gains spatial depth: soft bright top → identity mid → tone-down
        // bottom (same hue, slightly more saturated but never gray).
        let topS = min(max(hsb.s * 0.70, 0.12), ArtworkColorTuning.lightSaturationCap)
        let top = ArtworkColorMath.color(h: hsb.h, s: topS, b: min(hsb.b * 1.05, 0.98))
        let mid = base
        let bottomS = min(hsb.s * 1.25, 0.45)
        let bottom = ArtworkColorMath.color(h: hsb.h, s: bottomS, b: max(hsb.b * 0.78, 0.65))
        let elevated = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.8, 0.22), b: min(max(hsb.b - 0.025, 0.0), 0.94))

        let texts = ArtworkColorMath.semanticText(on: base, isLight: true, increasedContrast: increasedContrast)
        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: mid, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: true
        )
    }

    /// Pure black / dark-neutral artwork keeps a near-black background in Light Mode with
    /// white text (Thriller-style).
    private static func darkNeutralLightPalette(increasedContrast: Bool) -> AppearanceColorPalette {
        // Near-black neutral gradient; no hue injected.
        let top = ArtworkColorMath.color(h: 0.58, s: 0.0, b: 0.12)
        let base = ArtworkColorMath.color(h: 0.58, s: 0.0, b: 0.085)
        let bottom = ArtworkColorMath.color(h: 0.58, s: 0.0, b: 0.05)
        let elevated = ArtworkColorMath.color(h: 0.58, s: 0.0, b: 0.16)
        // A near-black page needs a true high-contrast primary label even when the system's
        // increased-contrast setting is off.
        let texts = ArtworkColorMath.semanticText(on: base, isLight: false, increasedContrast: true)
        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: base, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: false
        )
    }

    /// Mid-tone achromatic artwork (metallic gray / silver texture) keeps a heavy dark-gray
    /// atmosphere with white text — not a pale light gray.
    private static func midToneNeutralLightPalette(rawBright: Double, increasedContrast: Bool) -> AppearanceColorPalette {
        let top = ArtworkColorMath.color(h: 0.58, s: 0.03, b: min(rawBright * 0.75, 0.34))
        let base = ArtworkColorMath.color(h: 0.58, s: 0.03, b: min(rawBright * 0.55, 0.26))
        let bottom = ArtworkColorMath.color(h: 0.58, s: 0.03, b: max(rawBright * 0.35, 0.12))
        let elevated = ArtworkColorMath.color(h: 0.58, s: 0.03, b: min(rawBright * 0.85, 0.40))
        let texts = ArtworkColorMath.semanticText(on: base, isLight: false, increasedContrast: increasedContrast)
        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: base, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: false
        )
    }

    /// Deep blue / purple artwork keeps a deep chromatic atmosphere in Light Mode with
    /// white text (Immortal-style).
    private static func deepChromaticLightPalette(hue: Double, rawSat: Double, rawBright: Double, increasedContrast: Bool) -> AppearanceColorPalette {
        let top = ArtworkColorMath.color(h: hue, s: min(max(rawSat * 1.1, 0.50), 0.85), b: max(rawBright * 0.8, 0.22))
        let base = ArtworkColorMath.color(h: hue, s: min(max(rawSat * 1.05, ArtworkColorTuning.darkSaturationFloor), 0.82), b: max(rawBright * 0.65, 0.17))
        let bottom = ArtworkColorMath.color(h: hue, s: min(max(rawSat * 1.2, 0.50), 0.90), b: max(rawBright * 0.5, 0.12))
        let elevated = ArtworkColorMath.color(h: hue, s: min(rawSat, 0.70), b: max(rawBright * 0.75, 0.24))
        let texts = ArtworkColorMath.semanticText(on: base, isLight: false, increasedContrast: increasedContrast)
        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: base, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: false
        )
    }

    // MARK: Page — Dark

    static func darkPage(from analysis: RawArtworkColorAnalysis, increasedContrast: Bool = false) -> AppearanceColorPalette {
        var hsb = ArtworkColorMath.hsb(analysis.backgroundCandidate) ?? (0, 0, 0)
        let rawSat = hsb.s
        let rawBright = hsb.b
        let hue = hsb.h

        // Core rule: Dark Mode **darkens** a color, it does NOT desaturate / neutralize it.
        // Only genuinely achromatic classes (black / white / neutral / silver) lose hue.
        switch analysis.colorClass {
        case .black:
            hsb.s = 0.0
            hsb.b = min(max(rawBright, 0.06), 0.12)
        case .white:
            hsb.s = 0.05
            hsb.b = 0.20
        case .neutral, .silver:
            // True neutrals only → dark neutral (cool gray), never blue/purple drift.
            hsb.h = rawSat < 0.05 ? 0.60 : hue
            hsb.s = min(rawSat, 0.08)
            hsb.b = min(max(rawBright, 0.18), 0.24)
        default:
            // Chromatic art (red/orange/yellow/green/cyan/blue/purple/pink/… incl. multi-color):
            // retain hue + substantial chroma, only drop luminance into the dark band.
            let band = ArtworkColorTuning.darkBrightness(for: analysis.colorClass)
            hsb.s = min(max(rawSat * ArtworkColorTuning.darkChromaRetention, ArtworkColorTuning.darkSaturationFloor), 0.85)
            hsb.b = min(max(rawBright * ArtworkColorTuning.darkLuminanceScale, band.floor), band.ceiling)
        }

        let base = ArtworkColorMath.color(h: hsb.h, s: hsb.s, b: hsb.b)
        // Gradient keeps the SAME hue down the page: top is the chromatic seed, bottom is a
        // deeper (near-black) version of that hue — never a desaturated gray.
        let top = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s + 0.05, 0.80), b: min(hsb.b + 0.05, 0.32))
        let mid = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.95, 0.65), b: min(hsb.b * 0.85, 0.24))
        let bottom = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s, 0.60), b: min(max(hsb.b * 0.55, 0.05), 0.15))
        let elevated = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.85, 0.60), b: min(hsb.b + 0.06, 0.30))
        let texts = ArtworkColorMath.semanticText(on: base, isLight: false, increasedContrast: increasedContrast)
        return AppearanceColorPalette(
            base: base, elevated: elevated, top: top, mid: mid, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: false
        )
    }

    // MARK: Player — always dark

    static func player(from analysis: RawArtworkColorAnalysis) -> AppearanceColorPalette {
        var hsb = ArtworkColorMath.hsb(analysis.backgroundCandidate) ?? (0, 0, 0)

        let neutral = hsb.s < 0.14
        if neutral {
            hsb.h = 0.58
            hsb.s = 0.05
            hsb.b = min(max(hsb.b, 0.12), 0.24)
        } else {
            // Player also preserves hue while dimming — white chrome stays readable on a
            // dark chromatic wash.
            hsb.s = min(max(hsb.s, ArtworkColorTuning.darkSaturationFloor), 0.70)
            hsb.b = min(max(hsb.b * ArtworkColorTuning.darkLuminanceScale, 0.10), 0.28)
        }

        let top = ArtworkColorMath.color(h: hsb.h, s: hsb.s, b: hsb.b)
        let mid = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.78, 0.44), b: min(hsb.b * 0.78, 0.18))
        let bottom = ArtworkColorMath.color(h: hsb.h, s: min(hsb.s * 0.5, 0.16), b: min(hsb.b * 0.48, 0.09))
        let texts = ArtworkColorMath.semanticText(on: top, isLight: false)
        return AppearanceColorPalette(
            base: top, elevated: mid, top: top, mid: mid, bottom: bottom,
            text1: texts.0, text2: texts.1, text3: texts.2, text4: texts.3, isLight: false
        )
    }
}

// MARK: - Classification

nonisolated enum ArtworkColorAnalysisClassifier {
    static func classify(hsb: (h: Double, s: Double, b: Double), luminance: Double, chroma: Double, skin: Double) -> ArtworkColorClass {
        if hsb.b < 0.06 || (luminance < 0.04 && hsb.s < 0.20) { return .black }
        if hsb.s < 0.12 && luminance >= 0.90 { return .white }
        // Only genuinely near-gray art is neutral. A light cyan/blue pastel keeps its hue
        // and must NOT be swallowed by the neutral/silver bucket.
        if hsb.s < 0.08 { return .neutral }
        if hsb.s < 0.35 && hsb.b >= 0.45 && luminance >= 0.42 { return .pastel }
        if skin > 0.5 { return .portrait }
        // Remaining chromatic colors (incl. moderate-chroma pastels) stay hue-preserving.
        return .saturated
    }
}

// MARK: - Color math

nonisolated enum ArtworkColorMath {
    static func srgb(_ color: Color) -> (Double, Double, Double)? {
        // Resolving through SwiftUI avoids the UIKit/AppKit bridge, which can intermittently
        // return a zero color when several artwork analyses run concurrently.
        let resolved = color.resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }

    static func hsb(_ color: Color) -> (h: Double, s: Double, b: Double)? {
        guard let rgb = srgb(color) else { return nil }
        let maximum = max(rgb.0, rgb.1, rgb.2)
        let minimum = min(rgb.0, rgb.1, rgb.2)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum
        guard delta > 0 else { return (0, saturation, maximum) }

        let sector: Double
        if maximum == rgb.0 {
            sector = ((rgb.1 - rgb.2) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb.1 {
            sector = (rgb.2 - rgb.0) / delta + 2
        } else {
            sector = (rgb.0 - rgb.1) / delta + 4
        }
        let hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
        return (hue, saturation, maximum)
    }

    static func color(h: Double, s: Double, b: Double) -> Color {
        let hue = (h < 0 ? h + 1 : h).truncatingRemainder(dividingBy: 1)
        let saturation = min(max(s, 0), 1)
        let brightness = min(max(b, 0), 1)
        let chroma = brightness * saturation
        let sector = hue * 6
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let rgb: (Double, Double, Double)

        switch sector {
        case 0..<1: rgb = (chroma, x, 0)
        case 1..<2: rgb = (x, chroma, 0)
        case 2..<3: rgb = (0, chroma, x)
        case 3..<4: rgb = (0, x, chroma)
        case 4..<5: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }

        // Explicit sRGB components remain inspectable on both UIKit and AppKit. SwiftUI's
        // HSB-backed Color can fail NSColor conversion on newer macOS SDKs and collapse to gray.
        return Color(.sRGB, red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }

    static func neutralized(_ color: Color) -> Color {
        guard let hsb = hsb(color) else { return color }
        return self.color(h: hsb.h, s: 0.02, b: min(max(hsb.b, 0.12), 0.88))
    }

    static func packed(_ rgb: (Double, Double, Double)) -> Int {
        let r = Int(min(max(rgb.0, 0), 1) * 255)
        let g = Int(min(max(rgb.1, 0), 1) * 255)
        let b = Int(min(max(rgb.2, 0), 1) * 255)
        return (r << 16) | (g << 8) | b
    }

    static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }

    static func oklab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
        let m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
        let s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// 0…1 — skin-tone influence. Used as a candidate *penalty*, not an exclusion.
    /// A full portrait may still surface a skin-derived tone, but with reduced confidence.
    static func skinInfluence(hsb: (h: Double, s: Double, b: Double)) -> Double {
        let hues = hsb.h < 0.12 || hsb.h > 0.92
        guard hues, hsb.s > 0.10, hsb.s < 0.68, hsb.b > 0.18, hsb.b < 0.98 else { return 0 }
        return min(1.0, 0.35 + hsb.s * 0.7)
    }

    static func isMetallic(hsb: (h: Double, s: Double, b: Double), luminance: Double, chroma: Double) -> Bool {
        if hsb.s > 0.18 { return false }
        if hsb.b < 0.4 || hsb.b > 0.92 { return false }
        // Low chroma + low saturation + mid brightness ≈ metal; hue is often ambiguous.
        return chroma < 0.06
    }

    static func isSilverHue(_ h: Double) -> Bool {
        // Metallic silver lives on ambiguous cool hues; prevent blue/purple drift.
        let cool = (h >= 0.5 && h <= 0.75) || h < 0.05
        return cool
    }

    /// Builds semantic text stops by walking a neutral foreground toward/away from the
    /// background until the requested WCAG contrast ratios are met — real colors, not mere
    /// opacity multipliers.
    static func semanticText(on background: Color, isLight: Bool, increasedContrast: Bool = false) -> (Color, Color, Color, Color) {
        let bg = srgb(background) ?? (isLight ? (1, 1, 1) : (0, 0, 0))
        let bgL = relativeLuminance(bg.0, bg.1, bg.2)
        let targets: [Double] = increasedContrast
            ? (isLight ? [21.0, 10.0, 7.0, 4.5] : [21.0, 10.0, 7.0, 4.5])
            : (isLight ? [7.0, 4.5, 3.0, 1.8] : [7.0, 4.5, 3.0, 1.8])

        func foreground(forTarget target: Double) -> Color {
            // Walk from full opposite toward the background until target contrast is reached.
            // Bounded loop (≤200) — never early-break on fgL == bgL, which returned BLACK text
            // on pure-black backgrounds (and white on white) because the start foreground
            // equalled the background luminance.
            var offset = 0.0
            let step = 0.02
            for _ in 0..<200 {
                let fg = isLight ? max(0.0, 1.0 - offset) : min(1.0, offset)
                let fgL = relativeLuminance(fg, fg, fg)
                if contrastRatio(fgL, bgL) >= target { break }
                offset += step
            }
            let fg = isLight ? max(0.0, 1.0 - offset) : min(1.0, offset)
            return Color(red: fg, green: fg, blue: fg)
        }

        return (
            foreground(forTarget: targets[0]),
            foreground(forTarget: targets[1]),
            foreground(forTarget: targets[2]),
            foreground(forTarget: targets[3])
        )
    }
}
