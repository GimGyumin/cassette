// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Cassette Design Tokens v1.9
// Rebrand: Cassette Red (#E22134) — replaces Electric Violet (#6C47F5)
// All colors are adaptive (light/dark) via Asset Catalog Color Sets.
// Asset Catalog entries must be created alongside this file (see spec below).

public enum CassetteColors {
    
    // MARK: — Accent
    /// Primary brand color. CTA, active icons, progress bars.
    /// Light/Dark: Cassette Red (see CassetteAccent.colorset)
    public static let accent = Color("CassetteAccent")
    
    /// Tinted background for badges, pills, active states.
    public static let accentBackground = Color("CassetteAccentBackground")
    
    /// Text/icon color on top of accentBackground.
    public static let accentForeground = Color("CassetteAccentForeground")
    
    // MARK: — Backgrounds
    public static let backgroundPrimary = Color("CassetteBackgroundPrimary")
    public static let backgroundSecondary = Color("CassetteBackgroundSecondary")
    public static let backgroundTertiary = Color("CassetteBackgroundTertiary")
    
    // MARK: — Text (Apple semantic labels — readable in light/dark; not brand purple)
    public static var textPrimary: Color { SemanticLabel.primary }
    public static var textSecondary: Color { SemanticLabel.secondary }
    public static var textTertiary: Color { SemanticLabel.tertiary }

    /// System label / status colors for descriptions, guidance, and warnings.
    public enum SemanticLabel {
        public static var primary: Color {
            #if os(iOS)
            Color(uiColor: .label)
            #elseif os(macOS)
            Color(nsColor: .labelColor)
            #else
            Color.primary
            #endif
        }

        public static var secondary: Color {
            #if os(iOS)
            Color(uiColor: .secondaryLabel)
            #elseif os(macOS)
            Color(nsColor: .secondaryLabelColor)
            #else
            Color.secondary
            #endif
        }

        public static var tertiary: Color {
            #if os(iOS)
            Color(uiColor: .tertiaryLabel)
            #elseif os(macOS)
            Color(nsColor: .tertiaryLabelColor)
            #else
            Color.secondary.opacity(0.8)
            #endif
        }

        public static var warning: Color {
            #if os(iOS)
            Color(uiColor: .systemOrange)
            #elseif os(macOS)
            Color(nsColor: .systemOrange)
            #else
            .orange
            #endif
        }

        public static var destructive: Color {
            #if os(iOS)
            Color(uiColor: .systemRed)
            #elseif os(macOS)
            Color(nsColor: .systemRed)
            #else
            .red
            #endif
        }
    }
    
    // MARK: — Structure
    public static let separator = Color("CassetteSeparator")
    public static let border = Color("CassetteBorder")
    
    // MARK: — Brand ramp (Cassette Red — use for active chips / gradients)
    public enum Violet {
        // Kept as `Violet` for call-site compatibility; values are now red.
        public static let v50  = Color(hex: "#FDE8EB")
        public static let v100 = Color(hex: "#FACDD3")
        public static let v200 = Color(hex: "#F49AA6")
        public static let v300 = Color(hex: "#FF6B7A")
        public static let v400 = Color(hex: "#F23B4F")
        public static let v500 = Color(hex: "#E22134") // base accent
        public static let v600 = Color(hex: "#B01020")
        public static let v700 = Color(hex: "#8A0C19")
        public static let v800 = Color(hex: "#5E0811")
        public static let v900 = Color(hex: "#3A050A")
    }
}

// MARK: - Color(hex:) helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/*
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  ASSET CATALOG SPEC — Colors.xcassets                                   │
 │  Create one Color Set per token. Set "Appearances" to "Any, Dark".      │
 ├──────────────────────────────────┬──────────────────┬───────────────────┤
 │  Color Set Name                  │  Light (Any)     │  Dark             │
 ├──────────────────────────────────┼──────────────────┼───────────────────┤
 │  CassetteAccent                  │  #E22134         │  #FF4554          │
 │  CassetteAccentBackground        │  #FDE8EB         │  #2E1417          │
 │  CassetteAccentForeground        │  #B01020         │  #FF6B7A          │
 │  CassetteBackgroundPrimary       │  #F6F4FF         │  #17141E          │
 │  CassetteBackgroundSecondary     │  #EDEAFF         │  #1A1728          │
 │  CassetteBackgroundTertiary      │  #FFFFFF         │  #231F35          │
 │  CassetteTextPrimary/Secondary/Tertiary  │  (unused assets — code uses UIColor.label family) │
 │  CassetteSeparator               │  #E22134 @ 12%   │  #FF4554 @ 15%    │
 │  CassetteBorder                  │  #E22134 @ 18%   │  #FF4554 @ 22%    │
 └──────────────────────────────────┴──────────────────┴───────────────────┘
 
 NOTE — CassetteAccent (Asset Catalog) is the app AccentColor for in-app chrome
 (tabs, toggles, CTAs). System alerts/action sheets must NOT inherit that red tint —
 system alert actions retain their semantic cancellation and destructive roles.
 
 WindowGroup { ... }
 .tint(CassetteColors.accent)
 
 Replace all references to the old orange token (previously #FF7F3F) with
 the new tokens. Search codebase for:
 — Color("CassetteOrange") or similar legacy names
 — Color(hex: "#FF7F3F") or hardcoded orange literals
 — Any gradient stops referencing the old orange
 */
