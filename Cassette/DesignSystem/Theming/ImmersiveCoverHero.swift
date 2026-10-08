// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// The Apple-Music-style immersive cover hero, shared across detail surfaces (playlist, album, …). It is the
/// FIRST item of a scroll container so it scrolls up with the content. Playlist/artist melt into the themed
/// body color; albums use an inset floating cover (full-player style) on a matching solid page.
///
/// Pair it with: a solid `bodyColor` page `.background(...)`, `.ignoresSafeArea(.container, edges: .top)` on
/// the scroll container (so the cover reaches the screen top), and a transparent nav bar.
struct ImmersiveCoverHero<Content: View>: View {
    let coverArtId: String?
    let coverImage: PlatformImage?
    let theme: PlaylistTheme
    let heroHeight: CGFloat
    /// Re-mount key so the cover reloads when it changes (e.g. an edit upload). Defaults to a constant.
    var coverRefreshID: AnyHashable = 0
    /// When true the cover keeps its square ratio and the content sits BELOW it (album/playlist covers shown in
    /// full); when false (default) the content floats over the full-bleed cover (artist photos).
    var contentBelow: Bool = false
    /// When `contentBelow` is true, use `.fill` instead of `.fit` so square album art is edge-to-edge
    /// (no letterboxed bands at the top/bottom of the hero).
    var fillCover: Bool = false
    /// Solid fill behind the sharp cover (album page color continuity). Playlist/artist leave nil.
    var meltTargetColor: Color? = nil
    /// Playlist/artist keep the blur melt; albums turn this off.
    var showBlurredMelt: Bool = true
    /// Narrower, lighter melt band when melt is on.
    var softMelt: Bool = false
    /// Soft drop shadow under a full-bleed cover (legacy). Prefer `floatingInset` for albums.
    var showsFloatingShadow: Bool = false
    var coverShadowColor: Color = Color.black.opacity(0.18)
    /// Full-player style: inset rounded square cover centered on the page color (album pages).
    var floatingInset: Bool = false
    /// Side inset for `floatingInset` (matches full player ~40pt on compact).
    var floatingHorizontalPadding: CGFloat = 40
    /// Top inset for `floatingInset` so the cover clears the transparent back / … nav chrome.
    var floatingTopPadding: CGFloat = CassetteSpacing.xxxxl + 72
    var contentTopPadding: CGFloat? = nil
    var contentBottomPadding: CGFloat = CassetteSpacing.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        if contentBelow {
            VStack(spacing: 0) {
                coverHero
                    .shadow(
                        color: showsFloatingShadow && !floatingInset ? coverShadowColor : .clear,
                        radius: showsFloatingShadow && !floatingInset ? 28 : 0,
                        y: showsFloatingShadow && !floatingInset ? 14 : 0
                    )
                content()
                    .padding(.top, contentTopPadding ?? (floatingInset || showsFloatingShadow ? CassetteSpacing.m : CassetteSpacing.s))
                    .padding(.bottom, contentBottomPadding)
            }
            .frame(maxWidth: .infinity)
        } else {
            ZStack(alignment: .bottom) {
                coverHero
                content()
                    .padding(.bottom, contentBottomPadding)
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var coverHero: some View {
        if floatingInset {
            floatingInsetCover
                .padding(.top, floatingTopPadding)
                .frame(height: heroHeight + floatingTopPadding)
                .frame(maxWidth: .infinity)
                .id(coverRefreshID)
        } else if contentBelow {
            PlaylistThemedBackground(
                coverArtId: coverArtId,
                coverImage: coverImage,
                theme: theme,
                heroHeight: heroHeight,
                lightMelt: true,
                preferFill: fillCover,
                meltTargetColor: meltTargetColor,
                showBlurredMelt: showBlurredMelt,
                softMelt: softMelt
            )
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .id(coverRefreshID)
        } else {
            GeometryReader { geo in
                let rawStretch = max(0, geo.frame(in: .global).minY)
                let stretch = rawStretch > 0.5 ? rawStretch : 0
                let width = max(geo.size.width, 1)
                PlaylistThemedBackground(
                    coverArtId: coverArtId,
                    coverImage: coverImage,
                    theme: theme,
                    heroHeight: heroHeight,
                    lightMelt: false,
                    meltTargetColor: meltTargetColor,
                    showBlurredMelt: showBlurredMelt,
                    softMelt: softMelt
                )
                .frame(width: width, height: heroHeight + stretch)
                .offset(y: -stretch)
                .id(coverRefreshID)
            }
            .frame(height: heroHeight)
        }
    }

    /// Square cover with side margins + rounded corners + soft shadow (matches FullPlayer flowingCover).
    private var floatingInsetCover: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let side = min(
                max(0, width - floatingHorizontalPadding * 2),
                height
            )
            // Same corner formula as FullPlayerView.flowingCover.
            let corner = max(14, side * 0.055)

            ZStack {
                if let meltTargetColor {
                    meltTargetColor
                }

                Group {
                    if let coverImage {
                        platformImage(coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let coverArtId {
                        CoverArtView(id: coverArtId, size: 600, initialImage: coverImage, contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: max(side, 1), height: max(side, 1))
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                // Soft lift like Now Playing — visible on light pages; subtle on dark matching covers.
                .shadow(color: coverShadowColor, radius: 28, y: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func platformImage(_ image: PlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}
