// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import SwiftUI
import CoreGraphics
@testable import Cassette

/// Verifies the appearance-independent raw analysis → independent Light/Dark palette
/// pipeline. The color-level seeds below stand in for the 15 artwork families from the
/// design brief; raster-only families (black+white mix, multi-color, gradient, photographic)
/// are represented by representative single-color seeds here and require image fixtures
/// for full-fidelity verification.
struct ArtworkColorAnalysisTests {
    @Test func whiteSleeveWithDarkPortraitAndSideLetteringDoesNotTurnSilver() throws {
        let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fill(CGRect(x: 108, y: 0, width: 20, height: 128))
        context.fill(CGRect(x: 30, y: 0, width: 60, height: 106))
        let palette = AlbumColorAnalyzer.generateArtworkPalette(from: try #require(context.makeImage()))
        let rgb = try #require(ArtworkColorMath.srgb(palette.background))
        #expect(min(rgb.0, rgb.1, rgb.2) >= 0.95)
        let page = AlbumAtmosphere.from(palette: palette)
        #expect(page.isLight)
        #expect(page.contentColor == .black)
    }

    @Test(arguments: [0.60, 0.70, 0.82])
    func mediumGrayAlbumUsesLegibleInk(brightness: Double) throws {
        let page = AlbumAtmosphere.from(dominantColor: Color(.sRGB, red: brightness, green: brightness, blue: brightness))
        #expect(page.isLight)
        #expect(page.contentColor == .black)
        #expect(contrast(page.contentColor, on: page.pageColor) >= 4.5)
    }


    nonisolated private static let seeds: [(name: String, color: Color)] = [
        ("pure-black", Color(red: 0.00, green: 0.00, blue: 0.00)),
        ("pure-white", Color(red: 1.00, green: 1.00, blue: 1.00)),
        ("black-white-mix", Color(red: 0.50, green: 0.50, blue: 0.50)),
        ("red", Color(red: 0.85, green: 0.13, blue: 0.20)),
        ("blue", Color(red: 0.00, green: 0.20, blue: 0.90)),
        ("green", Color(red: 0.09, green: 0.70, blue: 0.33)),
        ("pastel", Color(red: 1.00, green: 0.80, blue: 0.85)),
        ("silver", Color(red: 0.78, green: 0.80, blue: 0.82)),
        ("gold", Color(red: 0.85, green: 0.65, blue: 0.13)),
        ("portrait-skin", Color(red: 0.92, green: 0.68, blue: 0.55)),
        ("colorful-multicolor", Color(red: 0.95, green: 0.45, blue: 0.00)),
        ("mostly-white", Color(red: 0.97, green: 0.97, blue: 0.98)),
        ("mostly-black", Color(red: 0.02, green: 0.02, blue: 0.03)),
        ("gradient", Color(red: 0.60, green: 0.30, blue: 0.90)),
        ("photographic", Color(red: 0.00, green: 0.50, blue: 0.50)),
    ]

    @Test(arguments: seeds)
    func lightAndDarkPalettesAreIndependentAndReadable(seed: (name: String, color: Color)) {
        let analysis = RawArtworkColorAnalysis(color: seed.color)
        let light = ArtworkColorTransformer.lightPage(from: analysis)
        let dark = ArtworkColorTransformer.darkPage(from: analysis)

        // Dark palette must always be dark. Light palette is dark-adaptive for black /
        // deep-chromatic artwork (Identity First) — otherwise it must be light.
        #expect(!dark.isLight, "\(seed.name): dark palette should be dark")
        let expectsDarkAdaptive = Self.isDarkAdaptiveSeed(seed.color)
        #expect(light.isLight == !expectsDarkAdaptive, "\(seed.name): light palette dark-adaptive mismatch (expectsDarkAdaptive: \(expectsDarkAdaptive))")

        // Primary text must meet WCAG AA (4.5:1) on both appearances.
        let lightContrast = contrast(light.text1, on: light.base)
        let darkContrast = contrast(dark.text1, on: dark.base)
        #expect(lightContrast >= 4.5, "\(seed.name): light text1 contrast \(lightContrast)")
        #expect(darkContrast >= 4.5, "\(seed.name): dark text1 contrast \(darkContrast)")

        // Elevated surface must be distinct from base in both appearances.
        #expect(light.elevated != light.base, "\(seed.name): light elevated == base")
        #expect(dark.elevated != dark.base, "\(seed.name): dark elevated == base")
    }

    @Test
    func lightDarkAdaptiveForDeepChromatic() {
        // Immortal-like: deep blue/purple should stay a dark chromatic atmosphere in Light
        // Mode with WHITE text (semantic flip), never a light lavender-gray.
        let color = ArtworkColorMath.color(h: 250.0 / 360.0, s: 0.60, b: 0.35)
        let light = ArtworkColorTransformer.lightPage(from: RawArtworkColorAnalysis(color: color))

        #expect(!light.isLight, "Deep chromatic should produce a dark background in Light")
        let deg = hue(light.base) * 360.0
        #expect(deg >= 200.0 && deg <= 290.0, "hue drifted \(deg)")
        #expect(brightness(light.base) <= 0.45, "base too bright")
        #expect(contrast(light.text1, on: light.base) >= 7.0, "white text contrast too low")
    }

    @Test
    func lightDarkAdaptiveForBlackArtwork() {
        // Thriller-like: pure black artwork stays near-black in Light Mode with white text.
        let light = ArtworkColorTransformer.lightPage(from: RawArtworkColorAnalysis(color: .black))

        #expect(!light.isLight)
        #expect(brightness(light.base) <= 0.15, "black artwork base should stay near-black")
        #expect(contrast(light.text1, on: light.base) >= 10.0, "white text contrast too low")
    }

    @Test
    func lightBorderOverridesDarkSubject() {
        // "Bad": dark center subject but a light/white border → must stay a light theme with
        // dark text, not flip to dark. Build a black-backed analysis, then flip borderIsLight
        // to reproduce the white-edged artwork the analyzer now reports.
        var lightBorder = RawArtworkColorAnalysis(color: .black)
        lightBorder.borderIsLight = true
        let light = ArtworkColorTransformer.lightPage(from: lightBorder)
        #expect(light.isLight, "light border must force a light page")
        #expect(contrast(light.text1, on: light.base) >= 4.5, "dark text contrast too low")
    }

    @Test
    func lightMidToneNeutralIsDarkAdaptive() {
        // "Thriller 40": low-saturation metallic mid-gray (B 0.3~0.5) must read as a heavy
        // dark gray (white text), not pale light gray.
        let color = ArtworkColorMath.color(h: 0.58, s: 0.05, b: 0.38)
        let light = ArtworkColorTransformer.lightPage(from: RawArtworkColorAnalysis(color: color))

        #expect(!light.isLight, "mid-tone achromatic must be dark-adaptive")
        #expect(brightness(light.base) <= 0.30, "base should be dark gray, got \(brightness(light.base))")
        #expect(contrast(light.text1, on: light.base) >= 4.5, "white text contrast too low")
    }

    @Test(arguments: seeds)
    func darkBottomIsDeeperThanDarkTop(seed: (name: String, color: Color)) {
        let analysis = RawArtworkColorAnalysis(color: seed.color)
        let dark = ArtworkColorTransformer.darkPage(from: analysis)
        let topL = luminance(dark.top)
        let bottomL = luminance(dark.bottom)
        // Dark atmosphere should stabilize (get no lighter) toward the bottom.
        #expect(bottomL <= topL + 0.03, "\(seed.name): dark bottom is brighter than top")
    }

    @Test(arguments: seeds)
    func semanticTextHierarchyHasMonotonicEmphasis(seed: (name: String, color: Color)) {
        let analysis = RawArtworkColorAnalysis(color: seed.color)
        for palette in [ArtworkColorTransformer.lightPage(from: analysis),
                        ArtworkColorTransformer.darkPage(from: analysis)] {
            let c1 = contrast(palette.text1, on: palette.base)
            let c2 = contrast(palette.text2, on: palette.base)
            let c3 = contrast(palette.text3, on: palette.base)
            let c4 = contrast(palette.text4, on: palette.base)
            #expect(c1 >= c2 && c2 >= c3 && c3 >= c4, "\(seed.name): text emphasis is not monotonic \(c1) \(c2) \(c3) \(c4)")
        }
    }

    @Test
    func classificationRecognizesKeyFamilies() {
        let classOf: (Color) -> ArtworkColorClass = { RawArtworkColorAnalysis(color: $0).colorClass }
        #expect(classOf(.black) == .black)
        #expect(classOf(.white) == .white)
        #expect(classOf(Color(red: 0.92, green: 0.68, blue: 0.55)) == .portrait)
        #expect(classOf(Color(red: 0.85, green: 0.13, blue: 0.20)) == .saturated)
        #expect(classOf(Color(red: 1.00, green: 0.80, blue: 0.85)) == .pastel)
    }

    @Test
    func lightKeepsCoolHueIdentity() {
        // Regression: Immortal (blue/purple) must stay blue-purple in Light, not gray-lavender.
        let color = Color(red: 0.20, green: 0.12, blue: 0.60)
        let light = ArtworkColorTransformer.lightPage(from: RawArtworkColorAnalysis(color: color))

        let deg = hue(light.base) * 360.0
        #expect(deg >= 200.0 && deg <= 290.0, "Immortal light hue \(deg) outside blue/purple range")
        #expect(saturation(light.base) >= 0.20, "Immortal light saturation too low (lavender-gray)")
        let b = brightness(light.base)
        #expect(b >= 0.80 && b <= 0.90, "Immortal light brightness \(b) out of range")
    }

    @Test
    func lightGradientHasDepth() {
        // Regression: 5.0 [Acoustic] (rose/pink) gradient must descend in brightness
        // top→bottom while keeping the hue family — not a flat field.
        let color = Color(red: 0.91, green: 0.45, blue: 0.58)
        let light = ArtworkColorTransformer.lightPage(from: RawArtworkColorAnalysis(color: color))

        #expect(brightness(light.top) > brightness(light.bottom), "Light gradient has no top→bottom depth")
        #expect(brightness(light.bottom) <= 0.75 + 0.05, "Light bottom too bright (flat field)")
        #expect(saturation(light.bottom) > saturation(light.top), "Light bottom should deepen saturation")
    }

    @Test
    func darkKeepsChromaticHueIdentity() {
        // Regression: Jam(red/orange), 10CM(cyan), 5.0(pink), Immortal(blue/purple).
        let cases: [(String, Color)] = [
            ("jam-red-orange", Color(red: 0.90, green: 0.25, blue: 0.10)),
            ("10cm-cyan", Color(red: 0.55, green: 0.85, blue: 0.88)),
            ("5.0-pink", Color(red: 0.91, green: 0.45, blue: 0.58)),
            ("immortal-blue-purple", Color(red: 0.20, green: 0.12, blue: 0.60)),
        ]

        for (name, color) in cases {
            let analysis = RawArtworkColorAnalysis(color: color)
            let dark = ArtworkColorTransformer.darkPage(from: analysis)

            // Dark base must not collapse to a near-gray (saturation floor).
            let sat = saturation(dark.base)
            #expect(sat >= 0.40, "\(name): dark base saturation \(sat) too low (gray collapse)")

            // Hue must stay in the same family (allow minor wrap-around / pastel shifts).
            let rawHue = hue(color)
            let darkHue = hue(dark.base)
            #expect(hueDistance(rawHue, darkHue) <= 0.08, "\(name): hue drifted \(rawHue) → \(darkHue)")
        }
    }

    @Test
    func darkGradientKeepsSaturationTowardBottom() {
        // Immortal-like violet must keep its chroma (Apple Music S ≈ 44–50%) to the bottom,
        // never collapse to gray — "darker but not desaturated".
        let color = ArtworkColorMath.color(h: 250.0 / 360.0, s: 0.60, b: 0.55)
        let dark = ArtworkColorTransformer.darkPage(from: RawArtworkColorAnalysis(color: color))

        let baseSat = saturation(dark.base)
        let bottomSat = saturation(dark.bottom)
        #expect(baseSat >= 0.40, "base saturation \(baseSat)")
        #expect(bottomSat >= baseSat * 0.9, "bottom saturation \(bottomSat) collapsed vs base \(baseSat)")

        // Brightness curve mirrors Apple Music: top ~18%, mid ~26%, bottom ~13%.
        let h = hue(dark.base) * 360.0
        #expect(h >= 240.0 && h <= 260.0, "violet hue drifted \(h)")
    }

    @Test
    func playerPaletteIsAlwaysDark() {
        let brightRed = RawArtworkColorAnalysis(color: Color(red: 1.00, green: 0.20, blue: 0.20))
        let palette = ArtworkColorTransformer.player(from: brightRed)
        #expect(!palette.isLight)
        #expect(contrast(palette.text1, on: palette.base) >= 4.5)
    }

    // MARK: - Helpers

    private func contrast(_ foreground: Color, on background: Color) -> Double {
        guard let fg = ArtworkColorMath.srgb(foreground),
              let bg = ArtworkColorMath.srgb(background) else { return 0 }
        let l1 = ArtworkColorMath.relativeLuminance(fg.0, fg.1, fg.2)
        let l2 = ArtworkColorMath.relativeLuminance(bg.0, bg.1, bg.2)
        return ArtworkColorMath.contrastRatio(l1, l2)
    }

    private func luminance(_ color: Color) -> Double {
        guard let rgb = ArtworkColorMath.srgb(color) else { return 0 }
        return ArtworkColorMath.relativeLuminance(rgb.0, rgb.1, rgb.2)
    }

    private func hsb(_ color: Color) -> (h: Double, s: Double, b: Double) {
        ArtworkColorMath.hsb(color) ?? (0, 0, 0)
    }

    private func saturation(_ color: Color) -> Double { hsb(color).s }

    private func brightness(_ color: Color) -> Double { hsb(color).b }

    private func hue(_ color: Color) -> Double { hsb(color).h }

    /// Whether a seed is expected to take the dark-adaptive Light branch.
    private static func isDarkAdaptiveSeed(_ color: Color) -> Bool {
        let analysis = RawArtworkColorAnalysis(color: color)
        let hsb = ArtworkColorMath.hsb(color) ?? (0, 0, 0)
        let isDarkNeutral = analysis.isMostlyBlack
            || (hsb.b < ArtworkColorTuning.darkNeutralBrightnessThreshold
                && hsb.s < ArtworkColorTuning.darkNeutralSaturationThreshold)
        let isMidToneNeutral = hsb.s < ArtworkColorTuning.darkAdaptiveMidToneSaturationMax
            && hsb.b >= ArtworkColorTuning.darkAdaptiveMidToneBrightnessFloor
            && hsb.b < ArtworkColorTuning.darkAdaptiveMidToneBrightnessCeiling
        let isDeepChromatic = ArtworkColorTuning.isCoolHue(hsb.h)
            && hsb.b < ArtworkColorTuning.darkAdaptiveBrightnessThreshold
            && hsb.s > ArtworkColorTuning.darkAdaptiveSaturationThreshold
        return isDarkNeutral || isMidToneNeutral || isDeepChromatic
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    private func isAchromatic(_ color: Color) -> Bool {
        guard let rgb = ArtworkColorMath.srgb(color) else { return false }
        let delta = max(abs(rgb.0 - rgb.1), abs(rgb.1 - rgb.2), abs(rgb.0 - rgb.2))
        return delta < 0.01
    }
}
