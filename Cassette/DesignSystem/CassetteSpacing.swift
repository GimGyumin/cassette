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

/// Settings proportions shared by the root, subpages, and choice lists.
enum CassetteSettingsLayout {
    static let minimumRowHeight: CGFloat = 54
    static let rowInsets = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
}

enum CassetteAlbumLayout {
    /// Title begins over the darkened bottom of a textured sleeve.
    static let fadedHeadingStart: CGFloat = 1.04
    // Window safe-area headroom belongs to the sleeve, independently of the
    // title baseline. These offsets are proportional to the uncropped square.
    static let fadedWindowArtworkHeadroom: CGFloat = 0.075
    static let fadedWindowHeadingLead: CGFloat = 0.06
    static let fadedTitleLeadIn: CGFloat = 0.30
    static let fadedDetailsTail: CGFloat = 0.14
    /// Extend a narrow strip of the sleeve above its square, keeping the subject
    /// below the floating navigation controls without zooming/cropping the cover.
    static let fadedArtworkTopInset: CGFloat = 0.22
    static let fadedSmoothArtworkTopInset: CGFloat = 0.12
    /// Portrait/photo compositions continue actual pixels through the title area.
    static let photographicArtworkScale: CGFloat = 1.32
    static let photographicHeadroom: CGFloat = 0.14
    /// Crossfade the original lower edge into the cached edge color; never stretch lettering.
    static let fadedBottomBlend: CGFloat = 0.08
    static func fadedTopInset(for treatment: FadedArtworkTreatment) -> CGFloat {
        switch treatment {
        case .textured: return fadedArtworkTopInset
        case .smooth: return fadedSmoothArtworkTopInset
        case .graphic: return 0
        case .photographic: return photographicHeadroom
        }
    }
    static let fadedTopSample: CGFloat = 0.06
    static let fadedTopBlend: CGFloat = 0.04
    static let fadedControlSide: CGFloat = 52
    static let fadedPlayWidth: CGFloat = 160
    static let coverSideInset: CGFloat = 68
    static let minimumCoverSide: CGFloat = 180
    static let controlSide: CGFloat = 56
    static let insetPlayWidth: CGFloat = 165
}

// MARK: - Shadow presets

/// Cassette shadow values. In dark mode, shadows are invisible against black backgrounds;
/// use `CassetteCoverModifier` (via `.cassetteCoverStyle()`) which switches to a thin
/// border in dark mode automatically.
enum CassetteShadow {
    static let artworkTextRadius: CGFloat = 2
    static let artworkTextY: CGFloat = 1
    static let artworkTextOpacity: Double = 0.5
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
    /// Fade transparent scrolling content into its existing backdrop. Apply before
    /// button overlays and outside the scroll content, so only viewport edges fade.
    /// Opaque page backgrounds should use the native soft scroll-edge helpers below.
    func cassetteContentEdgeFade(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        mask {
            GeometryReader { geometry in
                let height = max(0, geometry.size.height)
                let ramp = Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.15625), location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.84375), location: 0.75),
                    .init(color: .black, location: 1)
                ])
                VStack(spacing: 0) {
                    LinearGradient(gradient: ramp, startPoint: .top, endPoint: .bottom)
                        .frame(height: min(max(0, top), height * 0.25))
                    Rectangle().fill(.black)
                    LinearGradient(gradient: ramp, startPoint: .bottom, endPoint: .top)
                        .frame(height: min(max(0, bottom), height * 0.30))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    func cassetteContentWidth(_ style: CassetteContentWidthStyle = .fill) -> some View {
        modifier(ContentWidthModifier(style: style))
    }

    /// Match upstream album pages: keep the system top-edge effect out of the
    /// cover/zoom surface, including while the navigation bar is transitioning.
    @ViewBuilder
    func cassetteHideTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    /// Album artwork can remain unobscured until content scrolls under the bar.
    /// Let the system blend content into fixed navigation chrome.
    @ViewBuilder
    func cassetteSoftTopScrollEdge(isVisible: Bool = true) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .scrollEdgeEffectHidden(!isVisible, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// Native bars own the backdrop and blend scrolling content into their material.
    /// Avoid a black overlay here: it ends at the viewport and leaves a visible seam.
    @ViewBuilder
    func cassetteSoftBottomScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .scrollEdgeEffectHidden(false, for: .bottom)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
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
