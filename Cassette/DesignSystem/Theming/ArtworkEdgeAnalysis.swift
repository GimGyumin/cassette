// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import Foundation
import SwiftUI

/// Image facts, kept separately from the user's presentation preference and page theme.
nonisolated struct ArtworkEdgeAnalysis: Codable, Equatable, Sendable {
    // v10 also lets a muted bottom boundary veto a saturated interior field.
    // The continuation and track-list canvas must describe the same edge.
    static let currentVersion = 10
    let version: Int
    let packedBackground: Int
    let uniformity: Double
    let matchingCorners: Int
    let isOpaque: Bool
    let isSeamless: Bool
    /// Deterministic identity of the downsampled pixels, including central artwork.
    let fingerprint: UInt64
    /// Optional so a persisted v1/v2 palette still decodes and can be re-prepared.
    var presentationStyle: AlbumArtworkStyle? = nil
    var fadedTreatment: FadedArtworkTreatment? = nil
    var packedTopBackground: Int? = nil
    var packedContentBackground: Int? = nil
    var packedBottomBackground: Int? = nil

    /// A version number alone does not prove a partially restored cache is usable.
    var isPreparedForCurrentPresentation: Bool {
        version == Self.currentVersion && presentationStyle != nil && fadedTreatment != nil
            && packedTopBackground != nil && packedBottomBackground != nil && packedContentBackground != nil
    }

    var topBackground: Color { packedTopBackground.map(Self.color) ?? background }
    var bottomBackground: Color { packedBottomBackground.map(Self.color) ?? background }

    var fadedBackground: Color {
        packedContentBackground.map(Self.color) ?? AlbumArtworkStyle.fadedContentBackground
    }
    var prefersDarkStatusBar: Bool {
        guard let packedTopBackground else { return false }
        let r = Double((packedTopBackground >> 16) & 255) / 255
        let g = Double((packedTopBackground >> 8) & 255) / 255
        let b = Double(packedTopBackground & 255) / 255
        return ArtworkColorMath.relativeLuminance(r, g, b) > 0.50
    }

    var contentBackground: Color {
        presentationStyle == .faded ? fadedBackground : background
    }

    var background: Color {
        Self.color(packedBackground)
    }
    private static func color(_ packed: Int) -> Color {
        Color(.sRGB, red: Double((packed >> 16) & 255) / 255,
              green: Double((packed >> 8) & 255) / 255, blue: Double(packed & 255) / 255)
    }
}

nonisolated enum FadedArtworkTreatment: String, Codable, Sendable {
    case textured, smooth, photographic, graphic
}

nonisolated enum AlbumArtworkStyle: String, Codable, Sendable {
    case uniform, faded, standard

    /// A neutral canvas keeps silver/colored textures from becoming a bright flat page.
    static var fadedContentBackground: Color {
        Color(.sRGB, red: 0.18, green: 0.18, blue: 0.18)
    }
}

nonisolated enum AlbumArtworkPreference: String, CaseIterable, Sendable {
    case automatic, fullBleed, card

    func usesFullBleed(analysis: ArtworkEdgeAnalysis?) -> Bool {
        style(analysis: analysis) != .standard
    }

    func style(analysis: ArtworkEdgeAnalysis?) -> AlbumArtworkStyle {
        // v3's classification remains usable while preparation upgrades its facts.
        guard let analysis, (3...ArtworkEdgeAnalysis.currentVersion).contains(analysis.version), analysis.isOpaque else { return .standard }
        switch self {
        case .automatic: return analysis.presentationStyle ?? .standard
        case .fullBleed: return analysis.presentationStyle == .uniform ? .uniform : .faded
        case .card: return .standard
        }
    }
}

/// Image-based presentation heuristics inferred from reference screenshots, not
/// Apple's private algorithm. Never uses an album/artist name as a special case.
/// Run on an artwork preparation task, not from body or a scroll callback.
nonisolated enum ArtworkEdgeAnalyzer {
    // Retain fine texture that a 64px reduction used to average into a solid gray.
    // Preparation supplies a 240px image; the page never runs this analysis.
    private static let size = 192
    private static let tolerance = 18

    static func analyze(_ image: CGImage) -> ArtworkEdgeAnalysis? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return nil }

        struct Pixel { let r: Int; let g: Int; let b: Int; let a: Int }
        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let i = (y * size + x) * 4
            return Pixel(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]), a: Int(pixels[i + 3]))
        }
        var sides = [[Pixel]](repeating: [], count: 4)
        // A thin inset band avoids JPEG edge ringing while still testing each side.
        for inset in 1...3 {
            for coordinate in 3..<(size - 3) {
                sides[0].append(pixel(coordinate, inset))
                sides[1].append(pixel(coordinate, size - inset - 1))
                sides[2].append(pixel(inset, coordinate))
                sides[3].append(pixel(size - inset - 1, coordinate))
            }
        }
        let samples = sides.flatMap { $0 }
        let middle = samples.count / 2
        let r = samples.map(\.r).sorted()[middle]
        let g = samples.map(\.g).sorted()[middle]
        let b = samples.map(\.b).sorted()[middle]
        func matches(_ p: Pixel) -> Bool {
            abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance && p.a >= 250
        }
        let uniformity = Double(samples.filter(matches).count) / Double(samples.count)
        let sideUniformity = sides.map { Double($0.filter(matches).count) / Double($0.count) }
        let corners = [(2, 2), (size - 3, 2), (2, size - 3), (size - 3, size - 3)]
        let matchingCorners = corners.filter { matches(pixel($0.0, $0.1)) }.count
        // Transparency anywhere in the sleeve must not be mistaken for opaque black.
        let isOpaque = stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 }
        let luminance = ArtworkColorMath.relativeLuminance(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let requiredUniformity = luminance > 0.94 ? 0.92 : 0.90
        // Side-specific checks reject portraits/lettering reaching an entire edge even
        // when three other white sides would dominate the pooled sample count.
        func solidMatch(_ p: Pixel) -> Bool {
            max(abs(p.r - r), abs(p.g - g), abs(p.b - b)) <= 3
        }
        let solidFraction = Double(samples.filter(solidMatch).count) / Double(samples.count)
        let seamless = isOpaque && uniformity >= requiredUniformity && solidFraction >= 0.90
            && matchingCorners >= 3 && sideUniformity.allSatisfy { $0 >= 0.80 }

        // A white perimeter alone is insufficient: broad printed lettering near the
        // bottom belongs to the sleeve (e.g. a white typography-led compilation).
        // A narrow central figure can still extend into an exact seamless canvas.
        let hasLowerGraphic = ((size * 7 / 10)..<(size - 3)).contains { y in
            let ink = (3..<(size - 3)).filter { x in
                let p = pixel(x, y)
                return max(abs(p.r - r), abs(p.g - g), abs(p.b - b)) > 48
            }
            guard let first = ink.first, let last = ink.last else { return false }
            return last - first > size / 4 && ink.count > size * 12 / 100
        }

        // The page color must continue the bottom of the sleeve, not a top logo,
        // side lettering or a bright face. Only the lower composition is
        // considered: a top-only logo must never become the page color.
        var lowerFamilies = [HueFamily](repeating: .init(), count: 25)
        var lowerWeight = 0.0
        var coherentPairs = 0, neighborPairs = 0
        for y in 0..<size {
            for x in 0..<size {
                let p = pixel(x, y)
                let hsv = HSV(r: p.r, g: p.g, b: p.b)
                // A local canvas continues the lower composition, not the brightest
                // color at the top. Keep neutrals as a real candidate; otherwise a
                // small red jacket can tint an otherwise near-black portrait.
                if y >= size * 3 / 5, hsv.v < 0.86 {
                    // Damp the outer fifth: side spines, vertical lettering and
                    // white margins should not outvote the bottom-center subject.
                    let lateralWeight = (x < size / 5 || x >= size * 4 / 5) ? 0.5 : 1.0
                    let localWeight = (1 + Double(y - size * 3 / 5) / Double(size)) * lateralWeight
                    let bin = hsv.s < 0.12 ? 24 : Int((hsv.h * 24).rounded()) % 24
                    lowerFamilies[bin].weight += localWeight
                    lowerFamilies[bin].saturation += hsv.s * localWeight
                    lowerFamilies[bin].brightness += hsv.v * localWeight
                    lowerFamilies[bin].values.append(hsv.v)
                    lowerWeight += localWeight
                }
                for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < size && ny < size {
                    let other = pixel(nx, ny)
                    if max(abs(p.r - other.r), abs(p.g - other.g), abs(p.b - other.b)) <= 24 {
                        coherentPairs += 1
                    }
                    neighborPairs += 1
                }
            }
        }
        let spatialCoherence = Double(coherentPairs) / Double(max(1, neighborPairs))

        // Local medians remove grain, but preserve abrupt changes caused by busy
        // illustrations, lettering or wide subjects intersecting an edge. Smooth
        // gradients may span many colors; they need not match one global median.
        func median(_ values: [Pixel]) -> Pixel {
            let mid = values.count / 2
            return Pixel(r: values.map(\.r).sorted()[mid], g: values.map(\.g).sorted()[mid],
                         b: values.map(\.b).sorted()[mid], a: 255)
        }
        // Sample only the lower-central window for the continuation color. Side
        // lettering, white margins and a top logo must not tint the strip that
        // melts into the page body.
        var lowerBand: [Pixel] = []
        for y in (size * 82 / 100)..<(size - 2) {
            for x in (size * 20 / 100)..<(size * 80 / 100) {
                lowerBand.append(pixel(x, y))
            }
        }
        let lower = lowerBand.isEmpty ? median(sides[1]) : median(lowerBand)
        let lowerHSV = HSV(r: lower.r, g: lower.g, b: lower.b)
        var maximumStep = 0
        for side in 0..<4 {
            var previous: Pixel?
            for start in stride(from: 3, to: size - 10, by: 8) {
                var tile: [Pixel] = []
                for along in start..<(start + 8) {
                    for inset in 1...3 {
                        switch side {
                        case 0: tile.append(pixel(along, inset))
                        case 1: tile.append(pixel(along, size - inset - 1))
                        case 2: tile.append(pixel(inset, along))
                        default: tile.append(pixel(size - inset - 1, along))
                        }
                    }
                }
                let current = median(tile)
                if let previous {
                    maximumStep = max(maximumStep, abs(current.r - previous.r),
                                      abs(current.g - previous.g), abs(current.b - previous.b))
                }
                previous = current
            }
        }
        let exactCanvas = seamless && !hasLowerGraphic
        // Avoid stretching non-square scans and busy mosaics merely because they
        // contain a dominant hue. Automatic mode is deliberately conservative.
        let aspect = Double(image.width) / Double(max(1, image.height))
        let squareSleeve = (0.95...1.05).contains(aspect)
        let canExtend = maximumStep <= 32 || spatialCoherence >= 0.82
        let style: AlbumArtworkStyle = !squareSleeve ? .standard
            : (exactCanvas ? .uniform : (isOpaque && canExtend ? .faded : .standard))
        // Compare adjacent border pixels rather than global color range: a smooth
        // light-to-dark gradient and fine silver grain need different fade policies.
        var variation = 0
        var pairs = 0
        for side in sides {
            for index in 1..<(size - 6) {
                let first = side[index - 1], second = side[index]
                variation += abs(first.r - second.r) + abs(first.g - second.g) + abs(first.b - second.b)
                pairs += 3
            }
        }
        let treatment: FadedArtworkTreatment
        if seamless && hasLowerGraphic { treatment = .graphic }
        else if maximumStep > 32 { treatment = .photographic }
        else { treatment = Double(variation) / Double(max(1, pairs)) > 3.5 ? .textured : .smooth }
        let top = median(sides[0])
        let lowerMean = Double(lower.r + lower.g + lower.b) / 3
        let chromatic = max(lower.r, lower.g, lower.b) - min(lower.r, lower.g, lower.b) > 6
        func canvasChannel(_ value: Int) -> Int {
            guard chromatic else { return 46 }
            return min(58, max(34, Int((42 + (Double(value) - lowerMean) * 0.5).rounded())))
        }
        let content: Int
        let lowerDominant = lowerFamilies.indices.max { a, b in
            lowerFamilies[a].weight == lowerFamilies[b].weight ? a > b : lowerFamilies[a].weight < lowerFamilies[b].weight
        } ?? 24
        let local = lowerFamilies[lowerDominant]
        let localShare = local.weight / max(1, lowerWeight)
        // Fallback for lower compositions without a large local field: pick the
        // strongest chromatic family *within the lower band only*. A red logo at
        // the top of the sleeve is deliberately not a candidate.
        let lowerChromaticDominant = (0..<24).max { a, b in
            lowerFamilies[a].weight == lowerFamilies[b].weight
                ? a > b : lowerFamilies[a].weight < lowerFamilies[b].weight
        } ?? 0
        let lowerChromatic = lowerFamilies[lowerChromaticDominant]
        let lowerChromaticShare = lowerChromatic.weight / max(1, lowerWeight)
        // Printed white sleeves and fine silver textures retain their neutral
        // treatment. A sparse lower collage falls back to the broad lower field.
        let localCanvas = treatment == .photographic && localShare >= (lowerDominant == 24 ? 0.65 : 0.28)
        // A neutral majority owns the page even when a small printed red bar
        // appears near the bottom (white typography sleeves).
        let neutralLowerCanvas = lowerDominant == 24 && localShare >= 0.65
        let localValues = local.values.sorted()
        let shadow = localValues.isEmpty ? 0 : localValues[Int(Double(localValues.count - 1) * 0.30)]
        // A saturated field spanning the lower composition should retain its
        // established deeper hue rather than become a pale local tint.
        let continuousColorField = lowerDominant < 24 && localShare >= 0.28
            && shadow > 0.35 && local.saturation / max(1, local.weight) > 0.50
        let darkBorder = sides[1].filter {
            max($0.r, $0.g, $0.b) <= 48 && max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) <= 10
        }
        let hueDistance = abs(lowerHSV.h - Double(lowerDominant) / 24)
        let boundaryDisagrees = lowerDominant < 24 && min(hueDistance, 1 - hueDistance) > 0.125
        if Double(darkBorder.count) / Double(sides[1].count) >= 0.65 {
            // A black sleeve border is part of the artwork, not a missing color.
            // Interior gold/skin/red must not replace this boundary with brown.
            let border = median(darkBorder)
            content = border.r << 16 | border.g << 8 | border.b
        } else if lowerHSV.s <= 0.25, lowerHSV.v < 0.86 {
            // Gray/softly tinted bottom edges must not acquire a saturated hue
            // from a jacket, silhouette or lettering farther inside the sleeve.
            content = canvasChannel(lower.r) << 16 | canvasChannel(lower.g) << 8 | canvasChannel(lower.b)
        } else if lowerHSV.s > 0.25, lowerHSV.v < 0.86, boundaryDisagrees {
            // Even a narrow lower field owns the handoff. A large opposing hue
            // farther up must not turn a navy hem into a red track-list canvas.
            content = HSV.pack(hue: lowerHSV.h, saturation: lowerHSV.s,
                               brightness: min(0.24, max(0.09, lowerHSV.v * 0.52)))
        } else if neutralLowerCanvas {
            // A neutral majority still inherits the bottom-center tint instead of
            // becoming a flat gray. This preserves warm blacks while discarding
            // red top logos and white side margins.
            content = canvasChannel(lower.r) << 16 | canvasChannel(lower.g) << 8 | canvasChannel(lower.b)
        } else if localCanvas, !localValues.isEmpty, continuousColorField {
            let sourceValue = local.brightness / local.weight
            let saturation = min(0.90, max(0.35, local.saturation / local.weight * (sourceValue > 0.35 ? 1.35 : 0.90)))
            content = HSV.pack(hue: Double(lowerDominant) / 24, saturation: saturation,
                               brightness: min(0.34, max(0.11, sourceValue * 0.52)))
        } else if localCanvas, !localValues.isEmpty {
            // neutralLowerCanvas already handled a neutral majority, so this
            // branch is a chromatic local canvas.
            let saturation = min(0.88, local.saturation / local.weight)
            content = HSV.pack(hue: Double(lowerDominant) / 24, saturation: saturation,
                               brightness: min(0.24, max(0.09, shadow * 0.52)))
        } else if lowerChromatic.weight > 0, lowerChromaticShare >= 0.18 {
            let sourceValue = lowerChromatic.brightness / lowerChromatic.weight
            let saturation = min(0.90, max(0.35, lowerChromatic.saturation / lowerChromatic.weight * (sourceValue > 0.35 ? 1.35 : 0.90)))
            content = HSV.pack(hue: Double(lowerChromaticDominant) / 24, saturation: saturation,
                               brightness: min(0.34, max(0.11, sourceValue * 0.52)))
        } else {
            content = canvasChannel(lower.r) << 16 | canvasChannel(lower.g) << 8 | canvasChannel(lower.b)
        }
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for byte in pixels { fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211 }
        return ArtworkEdgeAnalysis(version: ArtworkEdgeAnalysis.currentVersion, packedBackground: r << 16 | g << 8 | b,
            uniformity: uniformity, matchingCorners: matchingCorners, isOpaque: isOpaque,
            isSeamless: seamless, fingerprint: fingerprint, presentationStyle: style,
            fadedTreatment: treatment, packedTopBackground: top.r << 16 | top.g << 8 | top.b,
            packedContentBackground: content,
            packedBottomBackground: lower.r << 16 | lower.g << 8 | lower.b)
    }

    private struct HueFamily {
        var weight = 0.0
        var saturation = 0.0
        var brightness = 0.0
        var values: [Double] = []
    }

    private struct HSV {
        let h: Double
        let s: Double
        let v: Double

        init(r: Int, g: Int, b: Int) {
            let r = Double(r) / 255, g = Double(g) / 255, b = Double(b) / 255
            let hi = max(r, g, b), lo = min(r, g, b), delta = hi - lo
            v = hi
            s = hi > 0 ? delta / hi : 0
            var hue = 0.0
            if delta > 0 {
                if hi == r { hue = (g - b) / delta }
                else if hi == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
            }
            h = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        }

        static func pack(hue: Double, saturation: Double, brightness: Double) -> Int {
            let h = hue * 6, c = brightness * saturation
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
            let rgb: (Double, Double, Double)
            switch Int(h) % 6 {
            case 0: rgb = (c, x, 0)
            case 1: rgb = (x, c, 0)
            case 2: rgb = (0, c, x)
            case 3: rgb = (0, x, c)
            case 4: rgb = (x, 0, c)
            default: rgb = (c, 0, x)
            }
            return Int(((rgb.0 + m) * 255).rounded()) << 16
                | Int(((rgb.1 + m) * 255).rounded()) << 8
                | Int(((rgb.2 + m) * 255).rounded())
        }
    }
}
