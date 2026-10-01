// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Apple-Music-style immersive background for the playlist detail view: the cover fills the top
/// **full-bleed** (edge-to-edge, under the nav bar via `.ignoresSafeArea`), a **blurred melt** fades it into
/// the themed body color around the start of the track list, and below that it's solid body color. The
/// detail content (title / by / transport) floats over the lower part of the cover.
///
/// Cover-agnostic — the same path renders a gradient JPEG, an uploaded photo, or a server album cover. The
/// blurred layer is flattened into one Metal-backed bitmap via `.drawingGroup()` (the FullPlayer pattern), so
/// the blur is rasterized once per cover change, never recomputed per frame. The only `#if os` is the
/// system-background bridge. Only the blurred cover is rasterized; the tone gradient stays live so it keeps
/// tracking the page tone; the over-scroll stretch is applied by the hero wrapper (`ImmersiveCoverHero`).
struct PlaylistThemedBackground: View {
    let coverArtId: String?
    let coverImage: PlatformImage?
    let theme: PlaylistTheme
    /// Height of the full-bleed cover region (from the screen top), beyond which it's solid body color.
    var heroHeight: CGFloat = 460
    /// When set (a user-picked gradient playlist), the hero renders the gradient CRISP from the spec instead
    /// of the uploaded JPEG. The JPEG stays the cards/cross-device source of truth; this is a local crisp
    /// enrichment. Default nil keeps every other caller (photo / server cover / ImmersiveCoverHero) unchanged.
    var gradientSpec: PlaylistGradientSpec? = nil
    /// Fade ONLY the bottom edge (square covers shown in full with content sitting below) instead of the lower
    /// ~half (full-bleed covers with content floating over them).
    var lightMelt: Bool = false
    /// Force `.fill` for the sharp hero layer even when `lightMelt` is on (album pages).
    var preferFill: Bool = false
    /// When set (album atmosphere), the melt dissolves into this color instead of `theme.dominantColor`.
    var meltTargetColor: Color? = nil
    /// Album pages keep a sharp square cover with no bottom blur; playlist/artist keep the melt.
    var showBlurredMelt: Bool = true
    /// Narrower, lighter bottom melt (album page) — less cover obscured than full `lightMelt`.
    var softMelt: Bool = false

    private var bodyColor: Color {
        if let meltTargetColor { return meltTargetColor }
        return theme.isThemed ? theme.dominantColor : systemBackground
    }
    private var sharpContentMode: ContentMode {
        (lightMelt && !preferFill) ? .fit : .fill
    }

    /// Melt band start (0…1 from top). Higher = less of the cover is blurred.
    private var meltClearStop: CGFloat {
        if softMelt { return 0.90 }
        return lightMelt ? 0.82 : 0.30
    }
    private var meltMaskClearStop: CGFloat {
        if softMelt { return 0.91 }
        return lightMelt ? 0.84 : 0.32
    }
    private var meltBlurRadius: CGFloat {
        softMelt ? 9 : 16
    }

    var body: some View {
        ZStack(alignment: .top) {
            bodyColor

            // Always paint the cover when we have an id — waiting for `theme.isThemed` left a blank
            // system-colored hero until dominant color resolved (looked like a mismatched page bg).
            if let coverArtId {
                ZStack(alignment: .top) {
                    // Sharp full-bleed cover — an ANIMATED mesh gradient from the spec (foreground only, cheap;
                    // the melt below stays static), else the artwork. Edge-to-edge.
                    Group {
                        if let gradientSpec {
                            AnimatedGradientHeroView(spec: gradientSpec)
                        } else if let coverImage {
                            platformImage(coverImage)
                                .resizable()
                                .aspectRatio(contentMode: sharpContentMode)
                        } else {
                            // Thumb/hero tier — avoid a second 1000px fetch racing the melt layer.
                            CoverArtView(id: coverArtId, size: 600, initialImage: coverImage, contentMode: sharpContentMode)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: heroHeight)
                    .clipped()

                    // Soft melt into body/atmosphere once the theme resolves; until then the sharp cover stands alone.
                    if showBlurredMelt, theme.isThemed || meltTargetColor != nil {
                        blurredMelt(coverArtId: coverArtId)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// The lower part of the hero: a blurred copy of the cover dissolving into the solid body color, masked
    /// so the top of the hero keeps the sharp cover.
    ///
    /// Only the blurred cover is rasterized (`.drawingGroup()` around the expensive blur). The tone gradient
    /// stays live: while it was flattened into the same bitmap, a page tone that resolved after the first
    /// pass jumped straight to its final colour inside the raster while the page background interpolated —
    /// the hero's last rows then held a different tone than the body and read as a hard horizontal seam
    /// above the first section (`Latest Release`).
    @ViewBuilder
    private func blurredMelt(coverArtId: String) -> some View {
        ZStack {
            Group {
                if let gradientSpec {
                    PlaylistGradientView(spec: gradientSpec)
                } else if let coverImage {
                    platformImage(coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Reuse the same request size as the sharp layer so ArtworkImageCache hits once.
                    CoverArtView(id: coverArtId, size: 600, initialImage: coverImage)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()
            .blur(radius: meltBlurRadius)
            .drawingGroup()

            // Resolve to the dominant body color EARLY so the transition reads as a colour continuity (the
            // cover melting into the dominant tint) rather than a washed-out blurred-cover band.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: meltClearStop),
                    .init(color: bodyColor, location: softMelt || lightMelt ? 1.0 : 0.80),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: heroHeight)
            .animation(CassetteAnimation.theme, value: bodyColor)
        }
        .frame(height: heroHeight)
        // Only the lower portion melts; the top keeps the sharp cover visible.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: meltMaskClearStop),
                    .init(color: .black, location: softMelt || lightMelt ? 1.0 : 0.85),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // The melt's terminal tone must animate exactly like the page background it meets.
        .animation(CassetteAnimation.theme, value: bodyColor)
    }

    private var systemBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
