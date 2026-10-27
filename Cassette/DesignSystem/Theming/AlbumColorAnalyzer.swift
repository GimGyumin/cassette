// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Apple Music–style multi-stop palette derived from album artwork.
///
/// The `background` here is the *raw artwork identity* seed. Appearance-specific
/// remapping (Light / Dark / player) happens later in `ArtworkColorTransformer`,
/// keeping the analysis independent of the display mode.
nonisolated struct ArtworkPalette: Equatable, Sendable {
    let background: Color
    let text1: Color
    let text2: Color
    let text3: Color
    let text4: Color
    /// Packed 0xRRGGBB of `background` for persistence / widgets.
    let packedBackground: Int
    var edgeAnalysis: ArtworkEdgeAnalysis? = nil
    var isProvisional: Bool? = nil
}

/// Outcome of analyzing one artwork: the legacy palette plus a rich, appearance-
/// independent `RawArtworkColorAnalysis`.
nonisolated struct ArtworkColorAnalysisResult: Equatable, Sendable {
    let palette: ArtworkPalette
    let raw: RawArtworkColorAnalysis
}

/// Apple Music–style artwork → raw color identity extractor.
///
/// Design note: Apple publishes `backgroundColor` / semantic text colors through artwork
/// metadata. For locally-analyzed artwork we reproduce a similar *visual* result using our
/// own perceptual heuristics. The numeric parameters below (border fraction, cluster count,
/// iterations, skin penalty, etc.) are project-tuned values, **not** Apple-endorsed
/// constants.
///
/// Pipeline (appearance-independent):
/// 1. 128×128 raster downsample (alpha < 0.08 dropped).
/// 2. Border decision tree: white / black / uniform (incl. pastel) / otherwise whole-image.
/// 3. Whole-image perceptual clustering (LAB) with skin *penalty* (not exclusion).
/// 4. Busy-scene detection → neutral anchoring.
/// 5. WCAG text contrast.
nonisolated enum AlbumColorAnalyzer {
    private static let analysisSize = 128
    private static let borderFraction = 0.09
    private static let clusterCount = 7
    private static let kMeansIterations = 10

    // MARK: - Public API

    static func generateArtworkPalette(from image: CGImage) -> ArtworkPalette {
        guard let resolution = resolve(image: image) else {
            return makePalette(rgb: RGB(0.17, 0.17, 0.18))
        }
        return resolution.palette
    }

    static func analyze(from image: PlatformImage, bottomStrip: Bool = false) -> ArtworkColorAnalysisResult? {
        guard let cg = cgImage(from: image) else { return nil }
        if bottomStrip {
            let h = cg.height
            let stripH = max(1, Int(Double(h) * 0.20))
            let y = max(0, h - stripH)
            if let cropped = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: stripH)) {
                return resolve(image: cropped)
            }
        }
        return resolve(image: cg)
    }

    static func rawAnalysis(from image: PlatformImage, bottomStrip: Bool = false) -> RawArtworkColorAnalysis? {
        guard let cg = cgImage(from: image) else { return nil }
        if bottomStrip {
            let h = cg.height
            let stripH = max(1, Int(Double(h) * 0.20))
            let y = max(0, h - stripH)
            if let cropped = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: stripH)) {
                return resolveColors(image: cropped)?.raw
            }
        }
        return resolveColors(image: cg)?.raw
    }

    static func packedBackground(from image: PlatformImage, bottomStrip: Bool = false) -> Int? {
        generateArtworkPalette(from: image, bottomStrip: bottomStrip)?.packedBackground
    }

    static func edgeAnalysis(from image: PlatformImage) -> ArtworkEdgeAnalysis? {
        cgImage(from: image).flatMap(ArtworkEdgeAnalyzer.analyze)
    }

    /// Explicit preparation combines layout facts with the existing color algorithm.
    /// Power budgets pace preparation; they must not change an album's background color.
    static func presentationPalette(from image: PlatformImage) -> ArtworkPalette? {
        guard let cg = cgImage(from: image) else { return nil }
        return presentationPalette(from: cg)
    }

    static func presentationPalette(from image: CGImage) -> ArtworkPalette? {
        guard let edges = ArtworkEdgeAnalyzer.analyze(image) else { return nil }
        var palette = generateArtworkPalette(from: image)
        palette.edgeAnalysis = edges
        palette.isProvisional = false
        return palette
    }

    static func generateArtworkPalette(from image: PlatformImage, bottomStrip: Bool = false) -> ArtworkPalette? {
        guard let cg = cgImage(from: image) else { return nil }
        if bottomStrip {
            let h = cg.height
            let stripH = max(1, Int(Double(h) * 0.20))
            let y = max(0, h - stripH)
            if let cropped = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: stripH)) {
                return generateArtworkPalette(from: cropped)
            }
        }
        return generateArtworkPalette(from: cg)
    }

    static func generateArtworkPalette(from image: PlatformImage) -> ArtworkPalette? {
        generateArtworkPalette(from: image, bottomStrip: false)
    }

    // MARK: - Resolution

    private static func resolve(image: CGImage) -> ArtworkColorAnalysisResult? {
        resolveColors(image: image)
    }

    private static func resolveColors(image: CGImage) -> ArtworkColorAnalysisResult? {
        guard let raster = Raster.make(from: image, size: analysisSize) else { return nil }

        let border = BorderStats.measure(raster, fraction: borderFraction)

        // Step 1: border decision tree.
        if border.isMostlyWhite {
            return pack(raw: RGB.lightThemeWhite, secondary: border.mean, neutral: RGB.lightThemeWhite, borderConfidence: border.cornerWhiteRatio, skin: 0, isMultiColor: false, borderIsLight: true)
        }
        if border.isBlackDominant {
            return pack(raw: .black, secondary: border.mean, neutral: .black, borderConfidence: border.darkRatio, skin: 0, isMultiColor: false)
        }
        if border.isUniform {
            return pack(raw: softPageColor(from: border.mean, preservePastel: true), secondary: border.mean, neutral: border.mean, borderConfidence: 0.9, skin: 0, isMultiColor: false)
        }

        let samples = Sample.collect(from: raster, borderFraction: borderFraction)
        guard !samples.isEmpty else {
            return pack(raw: softPageColor(from: border.mean, preservePastel: true), secondary: border.mean, neutral: border.mean, borderConfidence: border.meanBrightness, skin: 0, isMultiColor: false)
        }

        if let pastel = PastelField.detect(samples) {
            return pack(raw: softPageColor(from: pastel, preservePastel: true), secondary: pastel, neutral: pastel, borderConfidence: 0.75, skin: 0, isMultiColor: false, hinted: .pastel)
        }

        if let silver = MidSilver.detect(samples) {
            return pack(raw: silver, secondary: silver, neutral: silver, borderConfidence: 0.75, skin: 0, isMultiColor: false, hinted: .silver)
        }

        let clusters = KMeans.run(samples: samples, k: min(clusterCount, samples.count), iterations: kMeansIterations)
        guard let winner = ClusterPicker.best(clusters: clusters, total: samples.count) else {
            return pack(raw: softPageColor(from: border.mean, preservePastel: false), secondary: border.mean, neutral: border.mean, borderConfidence: 0.4, skin: 0, isMultiColor: false)
        }

        let page = softPageColor(from: winner.rgb, preservePastel: false)
        let skinInfluence = Skin.isSkinTone(winner.rgb) ? ArtworkColorMath.skinInfluence(hsb: winner.rgb.hsb) : 0

        // Busy / multi-hue scenes → neutral anchoring.
        if SceneFlags.shouldUseMatteBlack(samples: samples, candidate: page) {
            return pack(raw: .black, secondary: winner.rgb, neutral: .black, borderConfidence: border.darkRatio, skin: skinInfluence, isMultiColor: true)
        }

        let isMultiColor = SceneFlags.isMultiColor(samples: samples)
        let light = page.relativeLuminance > 0.55
        let final: RGB = (!light && !Contrast.whiteTextOK(on: page)) ? .black : page
        return pack(raw: final, secondary: winner.rgb, neutral: neutralized(final), borderConfidence: border.borderConfidence, skin: skinInfluence, isMultiColor: isMultiColor)
    }

    private static func pack(
        raw: RGB,
        secondary: RGB,
        neutral: RGB,
        borderConfidence: Double,
        skin: Double,
        isMultiColor: Bool,
        hinted: ArtworkColorClass? = nil,
        borderIsLight: Bool = false
    ) -> ArtworkColorAnalysisResult {
        let palette = makePalette(rgb: raw)
        let hsb = raw.hsb
        let l = raw.relativeLuminance
        let okl = raw.oklab
        let chroma = hypot(okl.a, okl.b)
        let cls = hinted ?? ArtworkColorAnalysisClassifier.classify(hsb: hsb, luminance: l, chroma: chroma, skin: skin)

        let rawAnalysis = RawArtworkColorAnalysis(
            primaryColor: raw.color,
            secondaryColor: secondary.color,
            neutralColor: neutral.color,
            backgroundCandidate: raw.color,
            confidence: cls == .multiColor || cls == .photographic ? 0.55 : 1.0,
            luminance: l,
            chroma: chroma,
            saturation: hsb.s,
            isMostlyBlack: hsb.b < 0.06 || (l < 0.04 && hsb.s < 0.20),
            isMostlyWhite: hsb.s < 0.12 && l >= 0.90,
            isNeutral: hsb.s < 0.14,
            isPastel: cls == .pastel,
            isMetallic: cls == .silver,
            isMultiColor: isMultiColor,
            borderConfidence: borderConfidence,
            skinToneInfluence: skin,
            borderIsLight: borderIsLight,
            colorClass: cls,
            packedBackground: raw.packed
        )
        return ArtworkColorAnalysisResult(palette: palette, raw: rawAnalysis)
    }

    private static func neutralized(_ rgb: RGB) -> RGB {
        var hsb = rgb.hsb
        hsb.s = 0.02
        hsb.b = min(max(hsb.b, 0.12), 0.88)
        return RGB(hsb: hsb)
    }

    // MARK: - Page color shaping

    private static func softPageColor(from raw: RGB, preservePastel: Bool) -> RGB {
        var hsb = raw.hsb
        if hsb.b < 0.08 { return .black }

        if preservePastel || (hsb.s < 0.28 && hsb.b >= 0.45) {
            hsb.s = min(max(hsb.s, 0.02), 0.45)
            hsb.b = min(max(hsb.b, 0.42), 0.92)
            return RGB(hsb: hsb)
        }
        if hsb.s < 0.08, hsb.b >= 0.55, hsb.b <= 0.90 {
            hsb.h = 0.58
            hsb.s = 0.03
            hsb.b = min(max(hsb.b * 0.92, 0.72), 0.80)
            return RGB(hsb: hsb)
        }
        hsb.s = min(hsb.s, 0.78)
        hsb.b = min(max(hsb.b, 0.12), 0.88)
        return RGB(hsb: hsb)
    }

    private static func makePalette(rgb: RGB) -> ArtworkPalette {
        let light = rgb.relativeLuminance > 0.55
        let texts = TextStops.colors(isLight: light)
        return ArtworkPalette(
            background: rgb.color,
            text1: texts.0,
            text2: texts.1,
            text3: texts.2,
            text4: texts.3,
            packedBackground: rgb.packed
        )
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #elseif canImport(AppKit)
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}

// MARK: - Raster

private nonisolated struct Raster {
    let size: Int
    let pixels: [UInt8] // RGBA

    static func make(from image: CGImage, size: Int) -> Raster? {
        let bpp = 4
        var pixels = [UInt8](repeating: 0, count: size * size * bpp)
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * bpp,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return Raster(size: size, pixels: pixels)
    }

    func rgb(x: Int, y: Int) -> RGB? {
        let i = (y * size + x) * 4
        guard Double(pixels[i + 3]) / 255.0 > 0.08 else { return nil }
        return RGB(
            Double(pixels[i]) / 255.0,
            Double(pixels[i + 1]) / 255.0,
            Double(pixels[i + 2]) / 255.0
        )
    }
}

// MARK: - Border stats (Step 1)

private nonisolated struct BorderStats {
    let mean: RGB
    let meanBrightness: Double
    let darkRatio: Double
    let nearWhiteRatio: Double
    let brightRatio: Double
    let cornerWhiteRatio: Double
    let topDarkRatio: Double
    let bottomDarkRatio: Double
    let labSpread: Double
    let maxDelta: Double

    var isMostlyWhite: Bool {
        if nearWhiteRatio >= 0.80 { return true }
        if brightRatio >= 0.80 { return true }
        // A dark portrait or a title stripe can occupy one side of a white sleeve.
        // Do not average those two fields into a nonexistent silver background.
        if nearWhiteRatio >= 0.55 && cornerWhiteRatio >= 0.45 && darkRatio < 0.45 { return true }
        if cornerWhiteRatio >= 0.75 && nearWhiteRatio >= 0.60 { return true }
        if cornerWhiteRatio >= 0.65 && meanBrightness >= 0.92 { return true }
        if nearWhiteRatio >= 0.65 && meanBrightness >= 0.93 { return true }
        if brightRatio >= 0.65 && meanBrightness >= 0.94 && darkRatio < 0.18 { return true }
        return false
    }

    var isBlackDominant: Bool {
        if isMostlyWhite { return false }
        if darkRatio >= 0.45 { return true }
        if topDarkRatio >= 0.55 { return true }
        if bottomDarkRatio >= 0.60 && darkRatio >= 0.28 { return true }
        if darkRatio >= 0.32 && darkRatio >= nearWhiteRatio && darkRatio >= brightRatio * 1.1 { return true }
        return false
    }

    var isUniform: Bool {
        if isMostlyWhite || isBlackDominant { return false }
        if meanBrightness < 0.08 { return false }
        if labSpread <= 10 && maxDelta <= 0.22 { return true }
        if labSpread <= 14 && maxDelta <= 0.16 && meanBrightness >= 0.35 { return true }
        return false
    }

    /// 0…1 — how likely the border represents a clean background.
    var borderConfidence: Double {
        if isMostlyWhite { return min(1.0, 0.4 + cornerWhiteRatio * 0.4 + nearWhiteRatio * 0.2) }
        if isBlackDominant { return min(1.0, 0.4 + darkRatio * 0.5) }
        if isUniform { return 0.85 }
        return 0.35
    }

    static func measure(_ raster: Raster, fraction: Double) -> BorderStats {
        let size = raster.size
        let band = max(2, Int(Double(size) * fraction))
        let corner = max(band, Int(Double(size) * 0.14))
        var sum = RGB(0, 0, 0)
        var count = 0.0
        var dark = 0.0, nearWhite = 0.0, bright = 0.0
        var topDark = 0.0, topN = 0.0, bottomDark = 0.0, bottomN = 0.0
        var cornerWhite = 0.0, cornerN = 0.0
        var labs: [LAB] = []
        var rgbs: [RGB] = []

        for y in 0..<size {
            for x in 0..<size {
                let onBorder = x < band || x >= size - band || y < band || y >= size - band
                guard onBorder, let rgb = raster.rgb(x: x, y: y) else { continue }
                sum = sum + rgb
                count += 1
                rgbs.append(rgb)
                labs.append(rgb.lab)
                if rgb.maxChannel <= 30.0 / 255.0 { dark += 1 }
                if rgb.minChannel >= 240.0 / 255.0 { bright += 1 }
                if rgb.minChannel >= 230.0 / 255.0 || rgb.mean >= 235.0 / 255.0 { nearWhite += 1 }
                if y < band {
                    topN += 1
                    if rgb.maxChannel <= 30.0 / 255.0 { topDark += 1 }
                }
                if y >= size - band {
                    bottomN += 1
                    if rgb.maxChannel <= 30.0 / 255.0 { bottomDark += 1 }
                }
                let isCorner =
                    (x < corner && y < corner)
                    || (x >= size - corner && y < corner)
                    || (x < corner && y >= size - corner)
                    || (x >= size - corner && y >= size - corner)
                if isCorner {
                    cornerN += 1
                    if rgb.minChannel >= 230.0 / 255.0 || rgb.mean >= 235.0 / 255.0 {
                        cornerWhite += 1
                    }
                }
            }
        }

        guard count > 0 else {
            return BorderStats(
                mean: RGB(0.5, 0.5, 0.5), meanBrightness: 0.5,
                darkRatio: 0, nearWhiteRatio: 0, brightRatio: 0, cornerWhiteRatio: 0,
                topDarkRatio: 0, bottomDarkRatio: 0, labSpread: 999, maxDelta: 999
            )
        }

        let mean = sum / count
        let meanLab = mean.lab
        var varLab = 0.0
        var maxDelta = 0.0
        for (i, lab) in labs.enumerated() {
            let dL = lab.L - meanLab.L, da = lab.a - meanLab.a, db = lab.b - meanLab.b
            varLab += dL * dL + da * da + db * db
            let d = rgbs[i] - mean
            maxDelta = max(maxDelta, sqrt(d.r * d.r + d.g * d.g + d.b * d.b))
        }

        return BorderStats(
            mean: mean,
            meanBrightness: mean.mean,
            darkRatio: dark / count,
            nearWhiteRatio: nearWhite / count,
            brightRatio: bright / count,
            cornerWhiteRatio: cornerN > 0 ? cornerWhite / cornerN : 0,
            topDarkRatio: topN > 0 ? topDark / topN : 0,
            bottomDarkRatio: bottomN > 0 ? bottomDark / bottomN : 0,
            labSpread: sqrt(varLab / count),
            maxDelta: maxDelta
        )
    }
}

// MARK: - Samples & special fields

private nonisolated struct Sample {
    let lab: LAB
    let rgb: RGB
    let edgeWeight: Double
    let isBorder: Bool

    static func collect(from raster: Raster, borderFraction: Double) -> [Sample] {
        let size = raster.size
        let band = max(2, Int(Double(size) * borderFraction))
        let center = Double(size - 1) / 2.0
        let maxDist = hypot(center, center)
        var out: [Sample] = []
        out.reserveCapacity(size * size / 2)
        for y in 0..<size {
            for x in 0..<size {
                guard let rgb = raster.rgb(x: x, y: y) else { continue }
                let dx = Double(x) - center, dy = Double(y) - center
                let dist = hypot(dx, dy) / max(maxDist, 1)
                out.append(Sample(
                    lab: rgb.lab,
                    rgb: rgb,
                    edgeWeight: 0.20 + 0.80 * dist,
                    isBorder: x < band || x >= size - band || y < band || y >= size - band
                ))
            }
        }
        return out
    }
}

private nonisolated enum PastelField {
    static func detect(_ samples: [Sample]) -> RGB? {
        var sum = RGB(0, 0, 0), w = 0.0
        var lowSatBright = 0
        for s in samples where s.isBorder || s.edgeWeight > 0.55 {
            let hsb = s.rgb.hsb
            guard hsb.s < 0.35, hsb.b >= 0.45, s.rgb.mean < 0.97 else { continue }
            lowSatBright += 1
            let weight = s.edgeWeight * (s.isBorder ? 1.5 : 1.0)
            sum = sum + s.rgb * weight
            w += weight
        }
        guard w > 0, Double(lowSatBright) / Double(max(samples.count, 1)) > 0.12 else { return nil }
        let mean = sum / w
        let hsb = mean.hsb
        guard hsb.s < 0.40, hsb.b >= 0.45 else { return nil }
        guard mean.mean < 0.94 else { return nil }
        return mean
    }
}

private nonisolated enum MidSilver {
    static func detect(_ samples: [Sample]) -> RGB? {
        var satSum = 0.0, lSum = 0.0, n = 0.0
        var midToneCount = 0.0
        var edgeSum = RGB(0, 0, 0), ew = 0.0
        for s in samples {
            let sat = s.rgb.saturation
            satSum += sat
            lSum += s.lab.L
            n += 1
            if sat < 0.14, s.lab.L >= 45, s.lab.L <= 88 { midToneCount += 1 }
            if s.isBorder || s.edgeWeight > 0.6, sat < 0.14, s.rgb.mean < 0.96 {
                edgeSum = edgeSum + s.rgb * s.edgeWeight
                ew += s.edgeWeight
            }
        }
        guard n > 0, midToneCount / n >= 0.35,
              satSum / n < 0.14, lSum / n >= 55, lSum / n <= 88, ew > 0 else { return nil }
        var hsb = (edgeSum / ew).hsb
        hsb.h = 0.58
        hsb.s = 0.03
        hsb.b = min(max(hsb.b, 0.72), 0.80)
        return RGB(hsb: hsb)
    }
}

private nonisolated enum SceneFlags {
    static func shouldUseMatteBlack(samples: [Sample], candidate: RGB) -> Bool {
        // Single bright / saturated colors must NOT collapse to black; only genuinely
        // busy multi-hue scenes anchor to neutral black.
        return isMultiColor(samples: samples) && labSpread(samples) > 28
    }

    static func isMultiColor(samples: [Sample]) -> Bool {
        var hueBuckets = [Int: Int]()
        let n = Double(samples.count)
        for s in samples {
            let hsb = s.rgb.hsb
            if hsb.s > 0.18, hsb.b > 0.12, hsb.b < 0.92 {
                hueBuckets[Int((hsb.h * 12).rounded(.down)) % 12, default: 0] += 1
            }
        }
        let distinct = hueBuckets.values.filter { Double($0) / n > 0.04 }.count
        return distinct >= 4
    }

    private static func labSpread(_ samples: [Sample]) -> Double {
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        let n = Double(samples.count)
        for s in samples {
            sumL += s.lab.L; sumA += s.lab.a; sumB += s.lab.b
        }
        let mean = LAB(L: sumL / n, a: sumA / n, b: sumB / n)
        var varLab = 0.0
        for s in samples {
            let dL = s.lab.L - mean.L, da = s.lab.a - mean.a, db = s.lab.b - mean.b
            varLab += dL * dL + da * da + db * db
        }
        return sqrt(varLab / n)
    }
}

// MARK: - K-means (LAB) + skin down-weight

private nonisolated struct Cluster {
    var lab: LAB
    var rgb: RGB
    var count: Int
    var edgeWeight: Double
}

private nonisolated enum KMeans {
    static func run(samples: [Sample], k: Int, iterations: Int) -> [Cluster] {
        guard k > 0, !samples.isEmpty else { return [] }
        let step = max(1, samples.count / k)
        var centroids = (0..<k).map { samples[min($0 * step, samples.count - 1)].lab }
        var assign = [Int](repeating: 0, count: samples.count)

        for _ in 0..<iterations {
            for (i, s) in samples.enumerated() {
                var best = 0, bestD = Double.greatestFiniteMagnitude
                for (ci, c) in centroids.enumerated() {
                    let d = LAB.distance2(s.lab, c)
                    if d < bestD { bestD = d; best = ci }
                }
                assign[i] = best
            }
            var sums = Array(repeating: LAB(L: 0, a: 0, b: 0), count: k)
            var counts = Array(repeating: 0, count: k)
            for (i, s) in samples.enumerated() {
                let c = assign[i]
                sums[c].L += s.lab.L; sums[c].a += s.lab.a; sums[c].b += s.lab.b
                counts[c] += 1
            }
            for ci in 0..<k where counts[ci] > 0 {
                let n = Double(counts[ci])
                centroids[ci] = LAB(L: sums[ci].L / n, a: sums[ci].a / n, b: sums[ci].b / n)
            }
        }

        var rgbSums = Array(repeating: RGB(0, 0, 0), count: k)
        var wSums = Array(repeating: 0.0, count: k)
        var counts = Array(repeating: 0, count: k)
        for (i, s) in samples.enumerated() {
            let c = assign[i]
            rgbSums[c] = rgbSums[c] + s.rgb
            wSums[c] += s.edgeWeight
            counts[c] += 1
        }
        return (0..<k).compactMap { ci in
            guard counts[ci] > 0 else { return nil }
            let n = Double(counts[ci])
            return Cluster(
                lab: centroids[ci],
                rgb: rgbSums[ci] / n,
                count: counts[ci],
                edgeWeight: wSums[ci] / n
            )
        }
    }
}

private nonisolated enum ClusterPicker {
    static func best(clusters: [Cluster], total: Int) -> Cluster? {
        let t = max(1, total)
        let scored = clusters.compactMap { c -> (Cluster, Double)? in
            let size = Double(c.count) / Double(t)
            if size < 0.03 { return nil }
            if c.lab.L < 6 || c.lab.L > 96 { return nil }
            let sat = c.rgb.saturation
            let chroma = hypot(c.lab.a, c.lab.b) / 128.0
            // Skin tone penalty — faces must not become the page color, but a full portrait
            // may still surface a skin-derived tone (reduced confidence, not exclusion).
            let skinPenalty = Skin.isSkinTone(c.rgb) ? 0.40 : 1.0
            let score = (
                0.50 * size
                + 0.30 * c.edgeWeight
                + 0.12 * min(chroma, 0.6)
                + 0.08 * min(sat, 0.5)
            ) * skinPenalty
            return (c, score)
        }
        .sorted { $0.1 > $1.1 }
        return scored.first?.0 ?? clusters.max(by: { $0.count < $1.count })
    }
}

private nonisolated enum Skin {
    static func isSkinTone(_ rgb: RGB) -> Bool {
        let hsb = rgb.hsb
        let warm = hsb.h < 0.12 || hsb.h > 0.92
        return warm && hsb.s > 0.12 && hsb.s < 0.65 && hsb.b > 0.18 && hsb.b < 0.78
    }
}

private nonisolated enum Contrast {
    static func whiteTextOK(on rgb: RGB) -> Bool {
        let bg = rgb.relativeLuminance
        return (max(1.0, bg) + 0.05) / (min(1.0, bg) + 0.05) >= 4.5
    }
}

private nonisolated enum TextStops {
    static func colors(isLight: Bool) -> (Color, Color, Color, Color) {
        if isLight {
            return (
                Color(red: 0.08, green: 0.08, blue: 0.10),
                Color(red: 0.18, green: 0.18, blue: 0.20).opacity(0.92),
                Color(red: 0.28, green: 0.28, blue: 0.30).opacity(0.78),
                Color(red: 0.35, green: 0.35, blue: 0.38).opacity(0.62)
            )
        }
        return (
            Color(red: 0.98, green: 0.97, blue: 0.95),
            Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.86),
            Color(red: 0.94, green: 0.93, blue: 0.90).opacity(0.68),
            Color(red: 0.92, green: 0.91, blue: 0.88).opacity(0.50)
        )
    }
}

// MARK: - Color math

private nonisolated struct RGB {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(hsb: (h: Double, s: Double, b: Double)) {
        let h = hsb.h.truncatingRemainder(dividingBy: 1)
        let s = min(max(hsb.s, 0), 1)
        let v = min(max(hsb.b, 0), 1)
        let i = Int(h * 6)
        let f = h * 6 - Double(i)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i % 6 {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }

    static let black = RGB(0, 0, 0)
    static let lightThemeWhite = RGB(0.97, 0.97, 0.975)

    var mean: Double { (r + g + b) / 3 }
    var maxChannel: Double { max(r, max(g, b)) }
    var minChannel: Double { min(r, min(g, b)) }
    var saturation: Double {
        let mx = maxChannel
        guard mx > 1e-6 else { return 0 }
        return (mx - minChannel) / mx
    }

    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let mx = maxChannel, mn = minChannel, d = mx - mn
        var h = 0.0
        if d > 1e-6 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx <= 1e-6 ? 0 : d / mx, mx)
    }

    var lab: LAB {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (R * 0.4124564 + G * 0.3575761 + B * 0.1804375) / 0.95047
        let y = (R * 0.2126729 + G * 0.7151522 + B * 0.0721750)
        let z = (R * 0.0193339 + G * 0.1191920 + B * 0.9503041) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return LAB(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    var oklab: (L: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = lin(r), gl = lin(g), bl = lin(b)
        let l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
        let m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
        let s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    var color: Color {
        Color(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1))
    }

    var packed: Int {
        (Int(min(max(r, 0), 1) * 255) << 16)
            | (Int(min(max(g, 0), 1) * 255) << 8)
            | Int(min(max(b, 0), 1) * 255)
    }

    static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    static func * (a: RGB, s: Double) -> RGB { RGB(a.r * s, a.g * s, a.b * s) }
    static func / (a: RGB, s: Double) -> RGB { RGB(a.r / s, a.g / s, a.b / s) }
}

private nonisolated struct LAB {
    var L: Double
    var a: Double
    var b: Double

    static func distance2(_ x: LAB, _ y: LAB) -> Double {
        let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return dL * dL + da * da + db * db
    }
}

#if canImport(UIKit)
extension UIImage {
    /// Apple Music–style page background from album artwork.
    func cassetteArtworkBackgroundColor() -> UIColor {
        guard let cg = cgImage else { return .systemGray6 }
        let palette = AlbumColorAnalyzer.generateArtworkPalette(from: cg)
        return UIColor(palette.background)
    }
}
#endif
