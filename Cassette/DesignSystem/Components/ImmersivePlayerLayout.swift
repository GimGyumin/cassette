// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Full-viewport proportions measured from the supplied Music player reference.
/// Geometry comes from the presenting window, including its actual safe areas.
struct ImmersivePlayerMetrics {
    let size: CGSize
    let topInset: CGFloat
    var bottomInset: CGFloat = 0
    var artworkTop: CGFloat { topInset + CassetteSpacing.s }
    var infoTop: CGFloat { min(size.height * 0.568, scrubberTop - 56) }
    var scrubberTop: CGFloat { min(size.height * 0.647, transportCenter - 92) }
    var transportCenter: CGFloat { min(size.height * 0.762, volumeCenter - 70) }
    var volumeCenter: CGFloat { min(size.height * 0.865, footerCenter - 46) }
    var footerCenter: CGFloat { min(size.height * 0.925, size.height - bottomInset - 40) }
    var contentWidth: CGFloat { max(0, size.width - 2 * CassetteSpacing.xxxl) }
    var infoWidth: CGFloat { max(0, size.width - CassetteSpacing.xxxl - 26) }
    /// Reference screenshots: 588×1280, playing cover (35, 140, 518, 518).
    /// Keep the cover above the title on short phones; never center it in the lyrics slot.
    var standardArtworkFrame: CGRect {
        let top = max(topInset + Self.panelTopGap, size.height * (140.0 / 1280.0))
        let side = max(0, min(size.width - 2 * Self.standardArtworkHorizontalInset,
                              infoTop - CassetteSpacing.xl - top))
        return CGRect(x: (size.width - side) / 2, y: top, width: side, height: side)
    }
    static let standardArtworkHorizontalInset: CGFloat = 24
    static let gripWidth: CGFloat = 60
    static let favoriteGlyph: CGFloat = 24
    static let menuGlyph: CGFloat = 20
    static let transportSkipGlyph: CGFloat = 28
    static let edgeBand: CGFloat = 0.04
    static let blendStart: CGFloat = 0.72
    static let footerHeight: CGFloat = 54
    static let footerGlyph: CGFloat = 20
    static let footerSelectionDiameter: CGFloat = 38
    static let flowingFooterReservation: CGFloat = 66
    static let panelTopGap: CGFloat = 34
    static let panelHeaderSide: CGFloat = 72
    static let upperArtworkBlend: CGFloat = 0.06
    static let dismissTapWidth: CGFloat = 160
    static let dismissTapHeight: CGFloat = 44
    static let landscapeTranslationGap: CGFloat = 12
}

/// Five stable slots: track info, seek controls, transport, volume, output toolbar.
/// Keeping their coordinates independent prevents title/quality changes moving rows.
struct ImmersivePlayerControlsLayout: Layout {
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var expandedPanel = false
    var showsStandardArtwork = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = ImmersivePlayerMetrics(size: bounds.size, topInset: topInset, bottomInset: bottomInset)
        let artwork = metrics.standardArtworkFrame
        let panelTop = showsStandardArtwork ? artwork.minY : topInset + ImmersivePlayerMetrics.panelTopGap
        let panelBottom = showsStandardArtwork ? artwork.maxY
            : (expandedPanel ? bounds.height - bottomInset - CassetteSpacing.s : metrics.scrubberTop - CassetteSpacing.l)
        let slots: [(CGFloat, CGFloat, CGFloat, UnitPoint)] = [
            (metrics.infoTop, metrics.infoWidth, 48, .top),
            (metrics.scrubberTop, metrics.contentWidth, 40, .top),
            (metrics.transportCenter, bounds.width * 0.73, 88, .center),
            (metrics.volumeCenter, metrics.contentWidth, 36, .center),
            (metrics.footerCenter, max(0, bounds.width - 2 * CassetteSpacing.xxl), ImmersivePlayerMetrics.footerHeight, .center),
            (panelTop, bounds.width, max(0, panelBottom - panelTop), .top)
        ]
        for (index, subview) in subviews.enumerated() where index < slots.count {
            let (y, width, height, anchor) = slots[index]
            let x = index == 0 ? bounds.minX + CassetteSpacing.xxxl + width / 2 : bounds.midX
            subview.place(at: CGPoint(x: x, y: bounds.minY + y), anchor: anchor,
                          proposal: ProposedViewSize(width: width, height: height))
        }
    }
}

enum ImmersivePlayerInk {
    static let primary = Color.white
    static let artist = Color.white.opacity(0.78)
    static let timing = Color.white.opacity(0.52)
    static let quality = Color.white.opacity(0.65)
    static let controls = Color.white.opacity(0.80)
}

/// A surface-independent footer in window coordinates. Safe-area insets are
/// measured by the caller; lyrics/queue content never participates in placement.
struct PortraitPlayerFooterLayout: Layout {
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let fullSize = CGSize(width: bounds.width, height: bounds.height + topInset + bottomInset)
        let metrics = ImmersivePlayerMetrics(size: fullSize, topInset: topInset, bottomInset: bottomInset)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + metrics.footerCenter - topInset),
                          anchor: .center, proposal: ProposedViewSize(
                            width: max(0, bounds.width - 2 * CassetteSpacing.xxl),
                            height: ImmersivePlayerMetrics.footerHeight))
        }
    }
}

/// Identical geometry on every player surface; no shadow or stretched capsule.
struct PlayerDismissHandle: View {
    let contentColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(contentColor.opacity(0.65))
                .frame(width: ImmersivePlayerMetrics.gripWidth, height: CassetteSpacing.xs)
                .frame(width: ImmersivePlayerMetrics.dismissTapWidth,
                       height: ImmersivePlayerMetrics.dismissTapHeight, alignment: .top)
                .padding(.top, CassetteSpacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }
}

/// Keep artwork layout stable while transport state animates its visual bounds.
struct PlayerArtworkPlaybackModifier: ViewModifier {
    let isPlaying: Bool
    let reduceMotion: Bool
    // 378px / 518px in the supplied paused/playing references.
    static let pausedScale: CGFloat = 0.73

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(isPlaying ? 0.32 : 0.16),
                    radius: isPlaying ? 24 : 12, y: isPlaying ? 12 : 6)
            .scaleEffect(isPlaying ? 1 : Self.pausedScale)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: isPlaying)
    }
}

/// Uses the exact square-height slot proposed by the portrait layout. Visual scale
/// never changes the slot or moves the track info, scrubber, or transport controls.
struct StandardPlayerArtworkSlot<Artwork: View>: View {
    let isPlaying: Bool
    let reduceMotion: Bool
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width - 2 * ImmersivePlayerMetrics.standardArtworkHorizontalInset,
                                  geometry.size.height))
            artwork(side)
                .frame(width: side, height: side)
                .modifier(PlayerArtworkPlaybackModifier(isPlaying: isPlaying, reduceMotion: reduceMotion))
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }
}
