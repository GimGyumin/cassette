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

/// The fade spans the title and its supporting information. Layout anchors keep
/// it aligned with real text bounds, including multi-line/accessibility titles.
struct FadedArtworkHero<Information: View>: View {
    let coverArtId: String
    let initialImage: PlatformImage?
    let background: Color
    let edgeColor: Color
    let topColor: Color
    var topInsetPoints: CGFloat?
    let title: String
    let treatment: FadedArtworkTreatment
    /// 0 = sharp, 1 = blurred artwork. The title and information are never blurred.
    var artworkBlurProgress: CGFloat = 0
    /// 0 = artwork visible, 1 = page background. Only the artwork/background
    /// group fades; the title, buttons and track list stay fully opaque.
    var artworkFadeProgress: CGFloat = 0
    private let information: Information

    init(coverArtId: String, initialImage: PlatformImage?, background: Color, title: String,
         treatment: FadedArtworkTreatment = .textured, edgeColor: Color? = nil, topColor: Color? = nil,
         topInsetPoints: CGFloat? = nil,
         artworkBlurProgress: CGFloat = 0, artworkFadeProgress: CGFloat = 0,
         @ViewBuilder information: () -> Information) {
        self.coverArtId = coverArtId
        self.initialImage = initialImage
        self.background = background
        self.edgeColor = edgeColor ?? background
        self.topColor = topColor ?? edgeColor ?? background
        self.topInsetPoints = topInsetPoints
        self.title = title
        self.treatment = treatment
        self.artworkBlurProgress = artworkBlurProgress
        self.artworkFadeProgress = artworkFadeProgress
        self.information = information()
    }

    private var topInsetFraction: CGFloat {
        CassetteAlbumLayout.fadedTopInset(for: treatment)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(1 / (CassetteAlbumLayout.fadedHeadingStart
                    - (topInsetPoints != nil ? CassetteAlbumLayout.fadedWindowHeadingLead : 0)
                    + (topInsetPoints == nil && treatment == .photographic ? CassetteAlbumLayout.photographicHeadroom : 0)), contentMode: .fit)
                .accessibilityHidden(true)
            if let topInsetPoints {
                Color.clear.frame(height: topInsetPoints).accessibilityHidden(true)
            }
            Text(title)
                .font(.cassetteFadedAlbumTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CassetteSpacing.xl)
                .padding(.vertical, CassetteSpacing.xs)
                .accessibilityAddTraits(.isHeader)
                .anchorPreference(key: FadedArtworkLayoutKey.self, value: .bounds) { .init(title: $0) }
            information
                .transformAnchorPreference(key: FadedArtworkLayoutKey.self, value: .bounds) { anchors, bounds in
                    anchors.information = bounds
                }
        }
        .backgroundPreferenceValue(FadedArtworkLayoutKey.self) { anchors in
            GeometryReader { geometry in
                let width = geometry.size.width
                let imageScale = treatment == .photographic ? CassetteAlbumLayout.photographicArtworkScale : 1
                let topInset = topInsetPoints.map {
                    $0 + (treatment == .photographic ? 0 : width * CassetteAlbumLayout.fadedWindowArtworkHeadroom)
                } ?? width * topInsetFraction
                let artworkBottom = topInset + width * imageScale
                let continuationStart = artworkBottom - width * imageScale * CassetteAlbumLayout.fadedBottomBlend
                let titleFrame = anchors.title.map { geometry[$0] }
                let informationFrame = anchors.information.map { geometry[$0] }
                let detailsFrame = anchors.details.map { geometry[$0] }
                let fadeStart = max(0, (titleFrame?.minY ?? geometry.size.height) - width * CassetteAlbumLayout.fadedTitleLeadIn)
                let fadeEnd = min(geometry.size.height,
                                  detailsFrame.map { $0.maxY + width * CassetteAlbumLayout.fadedDetailsTail }
                                  ?? informationFrame?.maxY ?? geometry.size.height)
                ZStack(alignment: .top) {
                    background
                    ZStack(alignment: .top) {
                        // Continue only the prepared top color. Stretching a strip
                        // repeats lettering (e.g. a logo at the very top of the sleeve).
                        topColor
                            .frame(height: topInset + width * imageScale * CassetteAlbumLayout.fadedTopBlend)
                        // Extend a color, not the last rows of the bitmap. Stretching
                        // those rows duplicates printed letters below the real cover.
                        edgeColor
                            .frame(height: max(0, geometry.size.height - continuationStart))
                            .offset(y: continuationStart)
                        artworkLayers(width: width, imageScale: imageScale, topInset: topInset)
                    }
                    // Fade one assembled cover, not each overlapping color/image
                    // separately. Otherwise the continuation rectangles show seams
                    // through translucent artwork while scrolling.
                    .compositingGroup()
                    .opacity(1 - min(max(artworkFadeProgress, 0), 1))
                    // Keep the title/button scrim outside the artwork fade group.
                    // It must remain dark while the artwork blurs and disappears;
                    // otherwise a light page colour leaks behind the white header.
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: background.opacity(0.25), location: 0.25),
                        .init(color: background.opacity(0.90), location: 0.70),
                        .init(color: background, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: max(0, fadeEnd - fadeStart))
                    .offset(y: fadeStart)
                    background
                        .frame(height: max(0, geometry.size.height - fadeEnd))
                        .offset(y: fadeEnd)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .clipped()
    }

    private func artworkLayers(width: CGFloat, imageScale: CGFloat, topInset: CGFloat) -> some View {
        let blur = min(max(artworkBlurProgress, 0), 1)
        let blurRadius = 28 * min(max(width / 390, 0.85), 1.8)
        return ZStack {
            // Keep the base opaque: a blurred overlay at alpha b already leaves
            // (1 - b) of the sharp image. Fading both makes their combined alpha
            // dip to 0.75 midway and exposes the hard edges of the backing colors.
            artwork(width: width)
            artwork(width: width)
                .blur(radius: blurRadius, opaque: true)
                .opacity(blur)
        }
        .compositingGroup()
        .mask {
            LinearGradient(stops: [
                .init(color: topInset > 0 ? .clear : .white, location: 0),
                .init(color: .white, location: CassetteAlbumLayout.fadedTopBlend),
                .init(color: .white, location: 1 - CassetteAlbumLayout.fadedBottomBlend),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .scaleEffect(imageScale, anchor: .top)
        .offset(y: topInset)
    }

    @ViewBuilder
    private func artwork(width: CGFloat) -> some View {
        Group {
            if let initialImage {
                #if canImport(UIKit)
                Image(uiImage: initialImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #elseif canImport(AppKit)
                Image(nsImage: initialImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #endif
            } else {
                CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero,
                             initialImage: initialImage, contentMode: .fit)
            }
        }
        .frame(width: width, height: width)
    }

}

nonisolated struct FadedArtworkLayoutAnchors {
    var title: Anchor<CGRect>? = nil
    var information: Anchor<CGRect>? = nil
    var details: Anchor<CGRect>? = nil
}

struct FadedArtworkLayoutKey: PreferenceKey {
    nonisolated static var defaultValue: FadedArtworkLayoutAnchors { .init() }
    nonisolated static func reduce(value: inout FadedArtworkLayoutAnchors, nextValue: () -> FadedArtworkLayoutAnchors) {
        let next = nextValue()
        value.title = next.title ?? value.title
        value.information = next.information ?? value.information
        value.details = next.details ?? value.details
    }
}
