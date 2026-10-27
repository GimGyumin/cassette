// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

enum AlbumScrollCoordinateSpace {
    static let name = "albumDetailScroll"
}

/// Scroll-linked artwork state. All values are derived directly from the scroll
/// distance; there is no implicit animation or delayed update.
nonisolated struct AlbumArtworkScrollProgress: Equatable, Sendable {
    var blur: CGFloat = 0
    var fade: CGFloat = 0

    init(distance: CGFloat, width: CGFloat, reduceMotion: Bool = false) {
        // The first experiment values (90…240 / 170…310) were tuned for a 390pt
        // phone. Scale them with the actual hero width so iPad and compact
        // phones transition at the same point in the artwork, not at a fixed
        // screen position.
        let scale = min(max(width / 390, 0.85), 1.8)
        blur = reduceMotion ? 0 : Self.smoothstep(90 * scale, 240 * scale, distance)
        fade = Self.smoothstep(170 * scale, 310 * scale, distance)
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Reads the hero's position in the album scroll view and feeds the artwork-only
/// blur/fade state into `FadedArtworkHero`. The state lives in this small wrapper
/// so scrolling does not re-evaluate the album's track list or navigation state.
struct ScrollLinkedFadedArtworkHero<Information: View>: View {
    let coverArtId: String
    let initialImage: PlatformImage?
    let background: Color
    let title: String
    let treatment: FadedArtworkTreatment
    let edgeColor: Color?
    let topColor: Color?
    let topInsetPoints: CGFloat?
    private let information: Information

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = AlbumArtworkScrollProgress(distance: 0, width: 390)

    init(coverArtId: String, initialImage: PlatformImage?, background: Color, title: String,
         treatment: FadedArtworkTreatment = .textured, edgeColor: Color? = nil, topColor: Color? = nil,
         topInsetPoints: CGFloat? = nil,
         @ViewBuilder information: () -> Information) {
        self.coverArtId = coverArtId
        self.initialImage = initialImage
        self.background = background
        self.title = title
        self.treatment = treatment
        self.edgeColor = edgeColor
        self.topColor = topColor
        self.topInsetPoints = topInsetPoints
        self.information = information()
    }

    var body: some View {
        FadedArtworkHero(
            coverArtId: coverArtId,
            initialImage: initialImage,
            background: background,
            title: title,
            treatment: treatment,
            edgeColor: edgeColor,
            topColor: topColor,
            topInsetPoints: topInsetPoints,
            artworkBlurProgress: progress.blur,
            artworkFadeProgress: progress.fade
        ) {
            information
        }
        .background {
            GeometryReader { geometry in
                let minY = geometry.frame(in: .named(AlbumScrollCoordinateSpace.name)).minY
                let distance = max(0, -minY)
                let width = max(geometry.size.width, 1)
                let next = AlbumArtworkScrollProgress(
                    distance: distance,
                    width: width,
                    reduceMotion: reduceMotion
                )
                Color.clear
                    .onChange(of: next, initial: true) { _, value in
                        if progress != value {
                            progress = value
                        }
                    }
            }
        }
    }
}
