// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A sharp sleeve below the status area, with extensions sampled from its edges.
/// The lower extension never includes the center portrait or stretched lettering.
struct ImmersiveNowPlayingBackground: View {
    let coverArtId: String
    let initialImage: PlatformImage?
    let fallbackColor: Color
    let metrics: ImmersivePlayerMetrics
    var lowerEdgeRGB: Int? = nil

    private var extensionExposure: Double {
        guard let rgb = lowerEdgeRGB else { return 0.60 }
        let peak = Double(max((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255)) / 255
        return min(1, 0.60 / max(peak, 0.01))
    }

    var body: some View {
        let width = metrics.size.width
        let height = metrics.size.height
        let controlsWash = 1 - 0.70 * extensionExposure
        ZStack(alignment: .top) {
            fallbackColor
            edgeStrip(width: width, lower: true)
                .scaleEffect(x: 1, y: height / max(1, width * ImmersivePlayerMetrics.edgeBand), anchor: .top)
                .frame(width: width, height: height, alignment: .top)
                .clipped()
                .blur(radius: width * 0.09, opaque: true)
                // Dim only after the sharp sleeve has fully handed off to the
                // extension. Multiplying the entire extension created a visible
                // dark band inside the artwork's crossfade.
                .overlay {
                    let end = min(1, (metrics.artworkTop + width) / max(height, 1))
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: end),
                        .init(color: .black.opacity(1 - extensionExposure), location: min(1, end + 0.12)),
                        .init(color: .black.opacity(1 - extensionExposure), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            edgeStrip(width: width, lower: false)
                .scaleEffect(x: 1, y: (metrics.artworkTop + width * ImmersivePlayerMetrics.upperArtworkBlend * 2)
                             / max(1, width * ImmersivePlayerMetrics.edgeBand), anchor: .top)
                .frame(width: width, height: metrics.artworkTop + width * ImmersivePlayerMetrics.upperArtworkBlend * 2, alignment: .top)
                .clipped()
                .blur(radius: width * ImmersivePlayerMetrics.upperArtworkBlend, opaque: true)
            artwork(width: width)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: ImmersivePlayerMetrics.upperArtworkBlend),
                        .init(color: .black, location: ImmersivePlayerMetrics.blendStart),
                        .init(color: .black.opacity(0.85), location: 0.82),
                        .init(color: .black.opacity(0.15), location: 0.96),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .offset(y: metrics.artworkTop)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.10), location: 0),
                .init(color: .black.opacity(0.10), location: 0.45),
                .init(color: .black.opacity(controlsWash), location: 0.568),
                .init(color: .black.opacity(max(0.34, controlsWash)), location: 0.62),
                .init(color: .black.opacity(0.64), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func artwork(width: CGFloat) -> some View {
        Group {
            if let initialImage {
                Image(platformImage: initialImage).resizable().scaledToFit()
            } else {
                CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero, contentMode: .fit)
            }
        }
            .frame(width: width, height: width)
            .clipped()
    }

    private func edgeStrip(width: CGFloat, lower: Bool) -> some View {
        let band = width * ImmersivePlayerMetrics.edgeBand
        return artwork(width: width)
            .offset(y: lower ? -(width - band) : 0)
            .frame(width: width, height: band, alignment: .top)
            .clipped()
    }
}
