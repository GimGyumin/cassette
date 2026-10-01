// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension CassetteColors {
    // Cassette Red foreground variants (replaces Electric Violet).
    // Light (#FF6B7A): WCAG relative luminance ≈ 0.35
    // Dark  (#B01020): WCAG relative luminance ≈ 0.08
    private static let accentFgLight = Color(hex: "#FF6B7A")
    private static let accentFgDark  = Color(hex: "#B01020")
    private static let luminanceFgLight: Double = 0.35
    private static let luminanceFgDark:  Double = 0.08
    static var contrastThreshold: Double = 3.0

    /// Returns whichever accentForeground variant achieves WCAG 2.1 contrast (≥3.0:1)
    /// against `background`. When neither passes (dead zone), returns accentFgDark.
    /// When both pass, prefers higher contrast. Falls back to `accentFgDark` when
    /// sRGB extraction is unavailable.
    static func accentForeground(on background: Color) -> Color {
        guard let lBg = sRGBLuminance(of: background) else { return accentFgDark }
        let cLight = contrastRatio(lBg, luminanceFgLight)
        let cDark  = contrastRatio(lBg, luminanceFgDark)
        let lightPasses = cLight >= contrastThreshold
        let darkPasses  = cDark  >= contrastThreshold
        if lightPasses != darkPasses { return lightPasses ? accentFgLight : accentFgDark }
        if !lightPasses { return accentFgDark }
        return lBg > 0.179 ? accentFgDark : accentFgLight
    }

    /// Dark cover → light (white) control surface; light cover → dark (black) control surface.
    static func prefersLightControl(on background: Color) -> Bool {
        guard let lBg = sRGBLuminance(of: background) else { return false }
        return contrastRatio(lBg, 1) > contrastRatio(lBg, 0)
    }

    /// Album/playlist Play CTA: capsule is black or white only; label/icon use a cover tint
    /// when it still meets contrast on that fill, otherwise fall back to opposite B/W.
    static func heroButtonVariant(
        on dominantColor: Color,
        labelTint: Color? = nil
    ) -> (background: Color, foreground: Color) {
        let fill: Color = prefersLightControl(on: dominantColor) ? .white : .black
        let fallback: Color = fill == .white ? .black : .white
        guard let tint = labelTint, meetsContrast(tint, on: fill) else {
            return (background: fill, foreground: fallback)
        }
        return (background: fill, foreground: tint)
    }

    /// Whether `foreground` has enough WCAG contrast against `background`.
    static func meetsContrast(_ foreground: Color, on background: Color, minimum: Double = 3.0) -> Bool {
        guard let lf = sRGBLuminance(of: foreground),
              let lb = sRGBLuminance(of: background) else { return false }
        return contrastRatio(lf, lb) >= minimum
    }

    // MARK: - WCAG 2.1 luminance

    static func sRGBLuminance(of color: Color) -> Double? {
        guard let (r, g, b) = sRGBComponents(of: color) else { return nil }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker  = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func linearize(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - Platform bridge

    private static func sRGBComponents(of color: Color) -> (Double, Double, Double)? {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
        #elseif canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        #else
        return nil
        #endif
    }
}
