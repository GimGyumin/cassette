// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - Spacing scale (4pt grid)

enum CassetteSpacing {
    static let xs: CGFloat    = 4
    static let s: CGFloat     = 8
    static let m: CGFloat     = 12
    static let l: CGFloat     = 16   // default horizontal screen padding
    static let xl: CGFloat    = 20
    static let xxl: CGFloat   = 24   // between sections
    static let xxxl: CGFloat  = 32
    static let xxxxl: CGFloat = 48

    /// Bottom scroll margin reserved for the iOS tabViewBottomAccessory mini player,
    /// which floats over tab content without extending the safe area.
    static let miniPlayerBottomMargin: CGFloat = 56
}

// MARK: - Corner radius scale

enum CassetteCornerRadius {
    static let xs: CGFloat       = 4
    static let s: CGFloat        = 6
    static let standard: CGFloat = 8    // all cover arts, most cards
    static let large: CGFloat     = 12   // full-player cover art, sheets
    static let hero: CGFloat      = 20   // Wrapped stat hero, year card
    static let pill: CGFloat      = 999  // capsule buttons
}

// MARK: - Shadow presets

/// Cassette shadow values. In dark mode, shadows are invisible against black backgrounds;
/// use `CassetteCoverModifier` (via `.cassetteCoverStyle()`) which switches to a thin
/// border in dark mode automatically.
enum CassetteShadow {
    static let coverRadius: CGFloat  = 8
    static let coverY: CGFloat       = 4
    static let coverOpacity: Double  = 0.15
}

// MARK: - Wide / desktop detail layout

/// Shared sizing for macOS + iPad regular detail/player surfaces (not iPhone compact).
enum CassetteWideLayout {
    /// Fixed album/playlist sidebar cover on desktop layouts.
    static let heroCoverArtSize: CGFloat = 280
    /// Sidebar column width (cover + horizontal padding).
    static let detailSidebarWidth: CGFloat = 320
    /// Full-player cover cap on wide layouts (iPad / macOS).
    static let playerCoverCap: CGFloat = 480
    /// Full-player cover cap on iPhone landscape.
    static let playerCoverCapCompactHeight: CGFloat = 240
    /// Reserved height under NavigationSplitView content for the floating bottom player bar.
    static let playerBarReservedHeight: CGFloat = 120

    /// macOS always; iPad regular width. iPhone compact stays on the phone Immersive stack.
    static func usesDesktopDetail(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    /// Full player “wide chrome”: desktop detail **or** iPhone landscape (compact height).
    static func usesWidePlayerLayout(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular || verticalSizeClass == .compact
        #endif
    }
}

#if os(macOS)
/// Legacy alias — prefer `CassetteWideLayout`.
enum CassetteMacOSLayout {
    static let heroCoverArtSize: CGFloat = CassetteWideLayout.heroCoverArtSize
    static let heroHeight: CGFloat = CassetteWideLayout.heroCoverArtSize + 64
    static let playerBarReservedHeight: CGFloat = CassetteWideLayout.playerBarReservedHeight
}
#endif

// MARK: - View modifier: content width

/// How aggressively content is centered on wide layouts (macOS windows, iPad regular width).
enum CassetteContentWidthStyle {
    /// Browse / home / discover — nearly fill the detail column.
    case fill
    /// Settings / dense text — keep a readable column.
    case readable
}

struct ContentWidthModifier: ViewModifier {
    var style: CassetteContentWidthStyle = .fill

    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Readable column: keeps dense text (settings, long lists) from stretching across a large window
    /// or a full-width iPad canvas. `.fill` is left alone — shelves and grids want the width.
    private func readableWidth(_ total: CGFloat) -> CGFloat {
        let inset: CGFloat = 48
        switch total {
        case ..<900:  return min(total - inset, 640)
        case ..<1200: return min(total - inset, 780)
        case ..<1600: return min(total - inset, 920)
        default:      return min(total - inset, 1080)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .containerRelativeFrame(.horizontal, alignment: .center) { total, _ in
                switch style {
                case .fill:     return max(320, total - 48)
                case .readable: return readableWidth(total)
                }
            }
        #else
        if horizontalSizeClass == .regular, style == .readable {
            // iPad at full width (or the wide half of Split View) gets the same readable cap as macOS;
            // iPhone stays edge-to-edge because it never has a regular horizontal size class.
            content
                .containerRelativeFrame(.horizontal, alignment: .center) { total, _ in
                    readableWidth(total)
                }
        } else {
            content
        }
        #endif
    }
}

extension View {
    func cassetteContentWidth(_ style: CassetteContentWidthStyle = .fill) -> some View {
        modifier(ContentWidthModifier(style: style))
    }

    /// Let the system soften scrolling content under the top bar; do not replace it
    /// with a fixed dark overlay or suppress the edge effect.
    @ViewBuilder
    func cassetteSoftTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .scrollEdgeEffectHidden(false, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Hides top + bottom scroll-edge blur (lyrics above chrome / translate controls).
    /// Do not set `.hard` first — that still paints a visible bottom band under lyrics.
    @ViewBuilder
    func cassetteHideScrollEdgeEffects() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}

// MARK: - View modifier: cover art style

struct CassetteCoverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(
                color: colorScheme == .dark ? .clear : .black.opacity(0.1),
                radius: 2,
                y: 1
            )
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.cassetteCoverBorder, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// Clips to a rounded rectangle, adds shadow in light mode and a thin border in dark mode.
    func cassetteCoverStyle(cornerRadius: CGFloat = CassetteCornerRadius.standard) -> some View {
        modifier(CassetteCoverModifier(cornerRadius: cornerRadius))
    }
}
