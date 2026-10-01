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

/// Mild refine of analyzer output into page / player atmospheres.
/// Trusts `AlbumColorAnalyzer` decisions — does **not** re-clamp white→silver or pastel→grey.
enum CoverColorRefiner {
    struct Atmosphere: Equatable, Sendable {
        let top: Color
        let mid: Color
        let bottom: Color
        let pageColor: Color
        let isLight: Bool
    }

    /// Album / playlist page fill from an already-decided dominant / border color.
    static func atmosphere(from raw: Color) -> Atmosphere {
        guard raw != .clear, let hsb = hsbComponents(raw) else {
            return Atmosphere(top: .clear, mid: .clear, bottom: .clear, pageColor: .clear, isLight: false)
        }

        let luminance = raw.luminance

        // Solid black from analyzer (Thriller / HIStory / complex art).
        if luminance < 0.04 || (hsb.b < 0.06 && hsb.s < 0.20) {
            return Atmosphere(top: .black, mid: .black, bottom: .black, pageColor: .black, isLight: false)
        }

        // Light theme white (Number Ones / Bad) — keep bright, tiny edge separation only.
        if hsb.s < 0.12 && luminance >= 0.90 {
            let page = color(hue: hsb.h, saturation: min(hsb.s, 0.03), brightness: min(max(hsb.b, 0.96), 0.985))
            return Atmosphere(top: page, mid: page, bottom: page, pageColor: page, isLight: true)
        }

        // Mid silver already shaped by analyzer (Invincible) — pass through.
        if hsb.s < 0.12 && luminance > 0.55 && luminance < 0.90 {
            let page = color(hue: 0.58, saturation: 0.03, brightness: min(max(hsb.b, 0.70), 0.82))
            return Atmosphere(top: page, mid: page, bottom: page, pageColor: page, isLight: true)
        }

        // Faithful chromatic / pastel backdrop — no forced darkening.
        let page = color(
            hue: hsb.h,
            saturation: min(max(hsb.s * 1.02, hsb.s), 0.90),
            brightness: min(max(hsb.b, 0.06), 0.92)
        )
        let bottom = color(
            hue: hsb.h,
            saturation: min(max(hsb.s, 0), 0.88),
            brightness: min(max(hsb.b * 0.97, hsb.b - 0.03), 0.90)
        )
        return Atmosphere(top: page, mid: page, bottom: bottom, pageColor: page, isLight: luminance > 0.58)
    }

    /// Now Playing wash — always dark enough for white chrome.
    static func playerAtmosphere(from raw: Color) -> Atmosphere {
        guard raw != .clear, let hsb = hsbComponents(raw) else {
            let fallback = color(hue: 0.60, saturation: 0.04, brightness: 0.22)
            return Atmosphere(top: fallback, mid: fallback, bottom: .black, pageColor: fallback, isLight: false)
        }

        var hue = hsb.h
        var sat = hsb.s
        var bright = hsb.b

        if sat < 0.14 {
            hue = 0.58
            sat = min(max(sat, 0.03), 0.10)
            if bright > 0.70 {
                bright = 0.38
            } else if bright > 0.40 {
                bright = min(max(bright * 0.55, 0.22), 0.40)
            } else {
                bright = min(max(bright + 0.06, 0.16), 0.34)
            }
        } else if bright > 0.86 && sat < 0.20 {
            hue = hue > 0.02 && hue < 0.15 ? 0.58 : hue
            sat = min(max(sat, 0.06), 0.14)
            bright = 0.36
        } else if bright > 0.62 || raw.luminance > 0.62 {
            sat = min(max(max(sat * 1.10, 0.14), sat), 0.65)
            bright = min(max(bright * 0.46, 0.28), 0.46)
        } else {
            sat = min(max(sat * 1.06, 0.12), 0.82)
            bright = min(max(bright, 0.18), 0.52)
        }

        let top = color(hue: hue, saturation: sat, brightness: bright)
        let mid = color(
            hue: hue,
            saturation: min(max(sat * 0.94, 0.04), 0.78),
            brightness: min(max(bright * 0.88, 0.14), 0.42)
        )
        let bottom = color(
            hue: hue,
            saturation: min(max(sat * 0.88, 0.03), 0.70),
            brightness: min(max(bright * 0.70, 0.10), 0.32)
        )
        return Atmosphere(top: top, mid: mid, bottom: bottom, pageColor: top, isLight: false)
    }

    private static func hsbComponents(_ color: Color) -> (h: Double, s: Double, b: Double)? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        #elseif canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        #else
        return nil
        #endif
        return (Double(h), Double(s), Double(b))
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> Color {
        Color(
            hue: hue.truncatingRemainder(dividingBy: 1),
            saturation: min(max(saturation, 0), 1),
            brightness: min(max(brightness, 0), 1)
        )
    }
}
