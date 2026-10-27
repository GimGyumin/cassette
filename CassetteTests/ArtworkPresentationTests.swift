// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Cassette

@Suite("Seamless artwork presentation")
struct ArtworkPresentationTests {
    @Test(arguments: [0.0, 120, 180, 220, 260, 310, 360])
    @MainActor func solidArtworkHasNoHorizontalSeamWhileScrolling(distance: Double) throws {
        let width = 402
        let source = try fixture(background: 0xb18555)
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let page = Color(.sRGB, red: 83 / 255, green: 54 / 255, blue: 23 / 255)
        let edge = Color(.sRGB, red: 177 / 255, green: 133 / 255, blue: 85 / 255)
        let progress = AlbumArtworkScrollProgress(distance: distance, width: CGFloat(width))
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            FadedArtworkHero(coverArtId: "scroll-seam", initialImage: initial,
                background: page, title: "FLOWERING", treatment: .smooth,
                edgeColor: edge, topColor: edge, topInsetPoints: 59,
                artworkBlurProgress: progress.blur, artworkFadeProgress: progress.fade) {
                Text("AKMU").font(.title).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.bottom, 100)
            }
            page.frame(height: 24)
        }.frame(width: CGFloat(width)).background(page))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        // These columns avoid title glyphs and measure the actual composited field,
        // including both ends of the cover-to-color continuation and the page join.
        for x in [2, 32, width - 3] {
            var maximumJump = 0
            for y in 1..<(image.height - 2) {
                let current = (y * width + x) * 4
                let previous = current - width * 4
                for channel in 0..<3 {
                    let jump = abs(Int(pixels[current + channel]) - Int(pixels[previous + channel]))
                    maximumJump = max(maximumJump, jump)
                }
            }
            #expect(maximumJump <= 3, "Hard horizontal color step at scroll distance \(distance), x=\(x)")
        }
        let url = URL(fileURLWithPath: "/tmp/cassette-album-scroll-\(Int(distance)).png")
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
    }

    private var artistInformationFixture: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.blue.frame(height: 1)
                Text("Artist").font(.cassetteAlbumArtist).foregroundStyle(.white)
                Text("Pop · 2022 · Lossless").font(.cassetteFootnote).foregroundStyle(.white)
                Color.green.frame(height: 1)
            }
            .anchorPreference(key: FadedArtworkLayoutKey.self, value: .bounds) { .init(details: $0) }
            Color.clear.frame(height: 120)
        }
        .frame(maxWidth: .infinity)
    }
    @Test func preparationRetainsOriginalPaletteAndOrdinaryColorReadsDoNotAnalyzeEdges() throws {
        for source in [try fixture(background: 0xfefefe), try fixture(background: 0x336699),
                       try fixture(background: 0xffffff, draw: { context in
                           context.setFillColor(CGColor(gray: 0, alpha: 1))
                           context.fill(CGRect(x: 56, y: 0, width: 8, height: 64))
                       })] {
            let original = AlbumColorAnalyzer.generateArtworkPalette(from: source)
            #expect(original.edgeAnalysis == nil)
            let prepared = try #require(AlbumColorAnalyzer.presentationPalette(from: source))
            #expect(prepared.packedBackground == original.packedBackground)
            #expect(prepared.text1 == original.text1)
            #expect(prepared.edgeAnalysis?.version == ArtworkEdgeAnalysis.currentVersion)
            #expect(prepared.isProvisional == false)
        }
    }

    @Test @MainActor func layoutsAreAccountScopedAndReplacementArtworkIsReanalyzed() async throws {
        let suite = "ArtworkPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try AppContainer(inMemory: true)
        let cache = ArtworkImageCache(downloadService: container.downloadService, libraryService: container.libraryService,
            serverService: container.serverService, serverState: container.serverState, presentationDefaults: defaults)
        let first = ServerSnapshot(from: ServerConfig(displayName: "First", baseURL: "https://first.example", username: "fixture"))
        let second = ServerSnapshot(from: ServerConfig(displayName: "Second", baseURL: "https://second.example", username: "fixture"))
        let id = "fixture-\(UUID())"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        func prepare(_ source: CGImage) async throws {
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, source, nil)
            #expect(CGImageDestinationFinalize(destination))
            #expect(await AlbumCoverPreloadService.prepareTheme(for: id, artworkImageCache: cache,
                dominantColorExtractor: nil, originalURL: url))
        }
        container.serverState.activeServer = first
        try await prepare(fixture(background: 0xfefefe))
        cache.setArtworkPreference(.card, for: id)
        #expect(cache.preparedPalette(for: id)?.edgeAnalysis?.packedBackground == 0xfefefe)

        container.serverState.activeServer = second
        #expect(cache.preparedPalette(for: id) == nil)
        #expect(cache.artworkPreference(for: id) == .automatic)
        try await prepare(fixture(background: 0x000000))
        #expect(cache.preparedPalette(for: id)?.edgeAnalysis?.packedBackground == 0x000000)
        #expect(cache.preparedPalette(for: id)?.packedBackground == 0x000000)

        container.serverState.activeServer = first
        #expect(cache.preparedPalette(for: id)?.edgeAnalysis?.packedBackground == 0xfefefe)
        #expect(cache.artworkPreference(for: id) == .card)
        // A second cache instance restores the choice without analyzing an image.
        let restored = ArtworkImageCache(downloadService: container.downloadService, libraryService: container.libraryService,
            serverService: container.serverService, presentationDefaults: defaults)
        #expect(restored.artworkPreference(for: id) == .card)
        restored.resetArtworkPreferences()
        #expect(restored.artworkPreference(for: id) == .automatic)
        await cache.invalidate(for: id)
        #expect(cache.preparedPalette(for: id) == nil)
        let changed = try fixture(background: 0xffffff) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 56, y: 0, width: 8, height: 64))
        }
        try await prepare(changed)
        #expect(cache.preparedPalette(for: id)?.edgeAnalysis?.isSeamless == false)
        await cache.invalidate(for: id)
        container.serverState.activeServer = second
        await cache.invalidate(for: id)
    }

    @Test @MainActor func renderedHeroPreservesCornersAndArtworkAtTheBottom() throws {
        let source = try fixture(background: 0xfefefe) { context in
            context.setFillColor(CGColor(red: 0.75, green: 0.55, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 28, y: 0, width: 8, height: 50))
        }
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let container = try AppContainer(inMemory: true)
        let background = try #require(ArtworkEdgeAnalyzer.analyze(source)).background
        let renderer = ImageRenderer(content: SeamlessArtworkHero(coverArtId: "synthetic-edge-fixture",
            initialImage: initial, background: background)
            .frame(width: 390)
            .environment(container.artworkImageCache).environment(\.appContainer, container))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == 390 && rendered.height == 390)
        var pixels = [UInt8](repeating: 0, count: 390 * 390 * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let sampled = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 390, height: 390,
                bitsPerComponent: 8, bytesPerRow: 390 * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 390, height: 390))
            return true
        }
        #expect(sampled)
        for (x, y) in [(0, 0), (389, 0), (0, 389), (389, 389)] {
            let offset = (y * 390 + x) * 4
            #expect(pixels[offset] >= 252 && pixels[offset + 1] >= 252 && pixels[offset + 2] >= 252)
            #expect(pixels[offset + 3] == 255)
        }
        // A fade/crop would remove the gold feet that reach one vertical image edge.
        let edgeColors = [1, 388].map { y -> Int in
            let offset = (y * 390 + 195) * 4
            return Int(pixels[offset]) - Int(pixels[offset + 2])
        }
        #expect(edgeColors.max()! > 100)
        let url = URL(fileURLWithPath: "/tmp/cassette-1006-seamless-hero.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rendered, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test @MainActor func fadedHeroKeepsUpperArtworkAndJoinsCanvasAtEveryWidth() throws {
        let source = try fixture(background: 0x999999)
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let container = try AppContainer(inMemory: true)
        for width in [320, 390, 430] {
            func render(_ title: String, size: DynamicTypeSize) throws -> CGImage {
                let renderer = ImageRenderer(content: VStack(spacing: 0) {
                    FadedArtworkHero(coverArtId: "faded-fixture", initialImage: initial,
                        background: AlbumArtworkStyle.fadedContentBackground, title: title,
                        edgeColor: Color(.sRGB, red: 0.6, green: 0.6, blue: 0.6)) {
                        artistInformationFixture
                    }
                    AlbumArtworkStyle.fadedContentBackground.frame(height: 24)
                }
                    .background(AlbumArtworkStyle.fadedContentBackground)
                    .frame(width: CGFloat(width))
                    .environment(\.dynamicTypeSize, size)
                    .environment(container.artworkImageCache).environment(\.appContainer, container))
                renderer.scale = 1
                return try #require(renderer.cgImage)
            }
            let image = try render("Thriller 40", size: .large)
            let expanded = try render("A very long album title that must remain fully readable at accessibility text sizes", size: .accessibility3)
            #expect(image.width == width && expanded.width == width)
            #expect(expanded.height > image.height)
            var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let sampled = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
                return true
            }
            #expect(sampled)
            let artistRow = try #require((0..<image.height).first { y in
                let i = (y * width + 2) * 4
                return bytes[i + 2] > 220 && bytes[i] < 30 && bytes[i + 1] < 180
            })
            let fadeStart = Int(Double(width) * 0.74)
            for y in 0..<max(0, fadeStart - 2) {
                let i = (y * width + 2) * 4
                #expect(abs(Int(bytes[i]) - 153) <= 2)
            }
            let detailsEnd = try #require((artistRow..<image.height).first { y in
                let i = (y * width + 2) * 4
                return bytes[i + 1] > 180 && bytes[i] < 90 && bytes[i + 2] < 90
            })
            let firstDark = try #require((0..<artistRow).first { y in
                let i = (y * width + 2) * 4
                return bytes[i] < 150 && abs(Int(bytes[i]) - Int(bytes[i + 2])) <= 2
            })
            #expect(firstDark >= fadeStart - 1)
            #expect(firstDark < fadeStart + max(10, (detailsEnd - fadeStart) / 8))
            #expect(bytes[((artistRow - 2) * width + 2) * 4] < 140)
            #expect(abs(Int(bytes[((detailsEnd + Int(Double(width) * 0.14) + 2) * width + 2) * 4]) - 46) <= 2)
            // Adjacent neutral background rows change gradually, rather than jumping
            // to a flat dark region beside the title. Skip the fixture's marker rows.
            for y in (firstDark + 1)..<detailsEnd {
                let i = (y * width + 2) * 4, previous = ((y - 1) * width + 2) * 4
                if abs(Int(bytes[i]) - Int(bytes[i + 2])) <= 2,
                   abs(Int(bytes[previous]) - Int(bytes[previous + 2])) <= 2 {
                    #expect(abs(Int(bytes[i]) - Int(bytes[previous])) <= 5)
                }
            }
            var expandedBytes = [UInt8](repeating: 0, count: width * expanded.height * 4)
            let expandedSampled = expandedBytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: expanded.height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(expanded, in: CGRect(x: 0, y: 0, width: width, height: expanded.height)); return true
            }
            #expect(expandedSampled)
            let expandedArtist = try #require((0..<expanded.height).first { y in
                let i = (y * width + 2) * 4
                return expandedBytes[i + 2] > 220 && expandedBytes[i] < 30 && expandedBytes[i + 1] < 180
            })
            #expect(expandedArtist > artistRow)
            #expect(expandedBytes[((expandedArtist - 2) * width + 2) * 4] < 140)
            #expect(abs(Int(expandedBytes[((fadeStart - 2) * width + 2) * 4]) - 153) <= 2)
            // Read clear of the title. One edge retains the source; the other is
            // exactly the content canvas, with neither a transparent seam nor border.
            // Sample inside the continuation, not the renderer's fractional last
            // scanline (ImageRenderer rounds the bitmap height up to a whole pixel).
            let edges = [0, image.height - 12].map { bytes[($0 * width + 2) * 4] }
            for y in (image.height - 26)...(image.height - 12) {
                #expect(abs(Int(bytes[(y * width + 2) * 4]) - 46) <= 2)
                #expect(bytes[(y * width + 2) * 4 + 3] == 255)
            }
            #expect(abs(Int(edges.max()!) - 153) <= 2)
            #expect(abs(Int(edges.min()!) - 46) <= 2)
            #expect(bytes[11] == 255 && bytes[((image.height - 12) * width + 2) * 4 + 3] == 255)
            if width == 390 {
                let url = URL(fileURLWithPath: "/tmp/cassette-1018-artist-fade.png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
    }

    @Test @MainActor func fadedHeroMovesTheSubjectBelowChromeWithoutZoomingTheSleeve() throws {
        let dimension = 64
        var sourceBytes = [UInt8](repeating: 153, count: dimension * dimension * 4)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = (y * dimension + x) * 4
                sourceBytes[offset + 3] = 255
                if (12..<20).contains(y), (26..<38).contains(x) {
                    sourceBytes[offset] = 240
                    sourceBytes[offset + 1] = 40
                    sourceBytes[offset + 2] = 40
                }
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(sourceBytes) as CFData))
        let source = try #require(CGImage(width: dimension, height: dimension, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: dimension * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let container = try AppContainer(inMemory: true)
        let width = 390
        let renderer = ImageRenderer(content: FadedArtworkHero(coverArtId: "subject-fixture", initialImage: initial,
            background: AlbumArtworkStyle.fadedContentBackground, title: "Thriller 40") {
                artistInformationFixture
            }
            .frame(width: CGFloat(width))
            .environment(container.artworkImageCache).environment(\.appContainer, container))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
        let sampled = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            return true
        }
        #expect(sampled)
        let redRows = (0..<image.height).filter { y in
            let offset = (y * width + width / 2) * 4
            return bytes[offset] > 220 && bytes[offset + 1] < 70 && bytes[offset + 2] < 70
        }
        let first = try #require(redRows.first)
        let last = try #require(redRows.last)
        // Marker stays at its source scale, after a top edge extension. A global
        // image scale/crop or an early dark mask would change these bounds/colors.
        #expect(abs(Double(first) / Double(width) - 0.4075) < 0.025)
        #expect(abs(Double(last - first) / Double(width) - 0.125) < 0.025)
        let url = URL(fileURLWithPath: "/tmp/cassette-1009-subject-hero.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func smoothSleevesCacheTheirOwnCanvasAndBrightTopSeparately() throws {
        let source = try fixture(background: 0xdce5e2) { context in
            for y in 0..<64 {
                context.setFillColor(CGColor(red: Double(212 - (63 - y)) / 255,
                    green: Double(224 - (63 - y)) / 255, blue: Double(220 - (63 - y)) / 255, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: 64, height: 1))
            }
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 28, y: 24, width: 8, height: 31))
        }
        let analysis = try #require(ArtworkEdgeAnalyzer.analyze(source))
        #expect(analysis.presentationStyle == .faded)
        #expect(analysis.fadedTreatment == .smooth)
        #expect(analysis.prefersDarkStatusBar)
        let packed = try #require(analysis.packedContentBackground)
        #expect(((packed >> 8) & 255) > ((packed >> 16) & 255))
        #expect(analysis.contentBackground != analysis.background)
        #expect(CassetteColors.meetsContrast(.white, on: analysis.contentBackground, minimum: 7))
        let restored = try JSONDecoder().decode(ArtworkEdgeAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(restored == analysis)
        let old = Data("""
            {"version":3,"packedBackground":10066329,"uniformity":1,"matchingCorners":4,
             "isOpaque":true,"isSeamless":false,"fingerprint":42,"presentationStyle":"faded"}
            """.utf8)
        let oldAnalysis = try JSONDecoder().decode(ArtworkEdgeAnalysis.self, from: old)
        #expect(AlbumArtworkPreference.automatic.style(analysis: oldAnalysis) == .faded)
        #expect(oldAnalysis.fadedTreatment == nil)
    }

    @Test @MainActor func bothTreatmentsKeepSubjectScaleAndHeadingAlignmentWithTitleFade() throws {
        let dimension = 64, width = 390
        var sourceBytes = [UInt8](repeating: 153, count: dimension * dimension * 4)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = (y * dimension + x) * 4
                sourceBytes[offset + 3] = 255
                if (24..<55).contains(y), (28..<36).contains(x) {
                    sourceBytes[offset] = 240; sourceBytes[offset + 1] = 40; sourceBytes[offset + 2] = 40
                }
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(sourceBytes) as CFData))
        let source = try #require(CGImage(width: dimension, height: dimension, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: dimension * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let container = try AppContainer(inMemory: true)
        func render(_ treatment: FadedArtworkTreatment) throws -> (Int, Int, Int) {
            let renderer = ImageRenderer(content: VStack(spacing: 0) {
                FadedArtworkHero(coverArtId: "lower-figure", initialImage: initial,
                    background: AlbumArtworkStyle.fadedContentBackground, title: "A Full-Length Figure", treatment: treatment, topColor: Color(.sRGB, red: 0.6, green: 0.6, blue: 0.6)) {
                    artistInformationFixture
                }
                AlbumArtworkStyle.fadedContentBackground.frame(height: 24)
            }.frame(width: CGFloat(width))
                .background(AlbumArtworkStyle.fadedContentBackground)
                .environment(container.artworkImageCache).environment(\.appContainer, container))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
            let sampled = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height)); return true
            }
            #expect(sampled)
            let red = (0..<image.height).filter { y in
                let i = (y * width + width / 2) * 4
                return bytes[i] > 180 && bytes[i + 1] < 90 && bytes[i + 2] < 90
            }
            let white = (0..<image.height).filter { y in
                (0..<width).contains { x in
                    let i = (y * width + x) * 4
                    return bytes[i] > 230 && bytes[i + 1] > 230 && bytes[i + 2] > 230
                }
            }
            let bottom = ((image.height - 12) * width + 2) * 4
            #expect(abs(Int(bytes[bottom]) - 46) <= 2 && bytes[bottom + 3] == 255)
            let url = URL(fileURLWithPath: "/tmp/cassette-1018-\(treatment.rawValue)-hero.png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return (try #require(red.first), try #require(red.last), try #require(white.first))
        }
        let smooth = try render(.smooth), textured = try render(.textured)
        #expect(abs(Double(textured.0 - smooth.0) / Double(width) - 0.10) < 0.02)
        #expect(abs(smooth.2 - textured.2) <= 1)
    }

    @Test(arguments: [0xfefefe, 0x000000, 0xc9bba5, 0x767676, 0x245799])
    func uniformSleevesPreserveExactEdgeColor(_ packed: Int) throws {
        let image = try fixture(background: packed) { context in
            context.setFillColor(CGColor(red: 0.7, green: 0.5, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 29, y: 12, width: 6, height: 46))
        }
        let result = try #require(ArtworkEdgeAnalyzer.analyze(image))
        #expect(result.isSeamless)
        #expect(result.packedBackground == packed)
        #expect(AlbumArtworkPreference.automatic.usesFullBleed(analysis: result))
        let atmosphere = AlbumAtmosphere.from(dominantColor: result.background,
                                              colorScheme: .dark, increaseContrast: false)
        #expect(atmosphere.pageColor == result.background)
        #expect(CassetteColors.meetsContrast(atmosphere.contentColor, on: result.background, minimum: 4.5))
    }

    @Test func aNarrowFigureAtTheBottomCanStayUncropped() throws {
        let image = try fixture(background: 0xfefefe) { context in
            context.setFillColor(CGColor(red: 0.75, green: 0.55, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 28, y: 0, width: 8, height: 50))
        }
        let analysis = try #require(ArtworkEdgeAnalyzer.analyze(image))
        #expect(analysis.isSeamless)
        #expect(analysis.uniformity < 1)
        #expect(analysis.matchingCorners == 4)
    }

    @Test func ordinaryPhotographicEdgesUseFullBleedButKeepTheCardOverride() throws {
        let striped = try fixture(background: 0xffffff) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 56, y: 0, width: 8, height: 64))
        }
        let portrait = try fixture(background: 0xffffff) { context in
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 16, y: 0, width: 32, height: 54))
        }
        for image in [striped, portrait] {
            let analysis = try #require(ArtworkEdgeAnalyzer.analyze(image))
            #expect(!analysis.isSeamless)
            #expect(AlbumArtworkPreference.automatic.style(analysis: analysis) == .faded)
            #expect(analysis.fadedTreatment == .photographic)
            #expect(!AlbumArtworkPreference.card.usesFullBleed(analysis: analysis))
            #expect(AlbumArtworkPreference.fullBleed.usesFullBleed(analysis: analysis))
        }
    }

    @Test func smoothGradientsAndSilverTextureUseFadedInsteadOfSolidPages() throws {
        let gradient = try fixture(background: 0xffffff) { context in
            for y in 0..<64 {
                context.setFillColor(CGColor(gray: Double(y) / 63, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: 64, height: 1))
            }
        }
        let textured = try fixture(background: 0x999999) { context in
            for y in 0..<64 {
                for x in 0..<64 {
                    let value = 140 + (x * 73 + y * 37 + x * y * 13) % 42
                    context.setFillColor(CGColor(gray: Double(value) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        #expect(ArtworkEdgeAnalyzer.analyze(gradient)?.fadedTreatment == .smooth)
        #expect(ArtworkEdgeAnalyzer.analyze(textured)?.fadedTreatment == .textured)
        for image in [gradient, textured] {
            let analysis = try #require(ArtworkEdgeAnalyzer.analyze(image))
            #expect(!analysis.isSeamless)
            #expect(analysis.presentationStyle == .faded)
            #expect(AlbumArtworkPreference.automatic.style(analysis: analysis) == .faded)
            #expect(analysis.contentBackground != analysis.background)
            let atmosphere = AlbumAtmosphere.from(dominantColor: analysis.contentBackground,
                                                  colorScheme: .light, increaseContrast: false)
            #expect(!atmosphere.isLight)
            #expect(CassetteColors.meetsContrast(.white, on: atmosphere.pageColor, minimum: 4.5))
        }
    }

    @Test func whiteTypographySleeveFadesButNarrowFigureRemainsSeamless() throws {
        let printed = try ordinarySleeve(.printed)
        let analysis = try #require(ArtworkEdgeAnalyzer.analyze(printed))
        // Its edges are genuinely white; the wide lower graphic changes presentation.
        #expect(analysis.isSeamless)
        #expect(analysis.presentationStyle == .faded)
        #expect(analysis.fadedTreatment == .graphic)
        #expect(analysis.packedContentBackground == 0x2e2e2e)
        #expect(analysis.prefersDarkStatusBar)
        #expect(AlbumArtworkPreference.fullBleed.style(analysis: analysis) == .faded)
        let narrow = try fixture(background: 0xffffff) { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 28, y: 0, width: 8, height: 50))
        }
        #expect(ArtworkEdgeAnalyzer.analyze(narrow)?.presentationStyle == .uniform)
    }

    @Test func ordinarySleevesUseTheirLargeColorFieldsRatherThanAFixedGray() throws {
        for kind in [OrdinarySleeve.navy, .red, .printed] {
            let result = try #require(ArtworkEdgeAnalyzer.analyze(ordinarySleeve(kind)))
            #expect(result.presentationStyle == .faded)
            #expect(CassetteColors.meetsContrast(.white, on: result.contentBackground, minimum: 7))
            let play = CassetteColors.heroButtonVariant(on: result.contentBackground, labelTint: result.contentBackground)
            #expect(play.background == .white && play.foreground == result.contentBackground)
            #expect(CassetteColors.meetsContrast(play.foreground, on: play.background, minimum: 7))
            let packed = try #require(result.packedContentBackground)
            let r = (packed >> 16) & 255, g = (packed >> 8) & 255, b = packed & 255
            switch kind {
            case .navy:
                #expect((6...20).contains(r) && (12...28).contains(g) && (22...38).contains(b))
                #expect(b > g && g > r)
                #expect(!result.prefersDarkStatusBar)
            case .red:
                #expect((70...95).contains(r) && (5...25).contains(g) && (5...25).contains(b))
                #expect(r > g * 3 && r > b * 3)
            case .printed:
                #expect(r == 46 && g == 46 && b == 46)
            }
            let repeated = try ordinarySleeve(kind)
            #expect(result == ArtworkEdgeAnalyzer.analyze(repeated))
        }
    }

    @Test func busyIllustrationWithoutACoherentCanvasCanStillUseStandard() throws {
        let source = try fixture(background: 0xffffff) { context in
            for y in 0..<64 {
                for x in 0..<64 {
                    let n = (x * 73 + y * 37 + x * y * 13) % 251
                    context.setFillColor(CGColor(gray: Double(n) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 24, width: 4, height: 24))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 24))
        }
        let result = try #require(ArtworkEdgeAnalyzer.analyze(source))
        #expect(result.presentationStyle == .standard)
        #expect(AlbumArtworkPreference.fullBleed.style(analysis: result) == .faded)
    }

    @Test @MainActor func ordinarySleevesRenderAnOpaqueContinuousCanvasAndPreservePrintedScale() throws {
        let container = try AppContainer(inMemory: true)
        for kind in [OrdinarySleeve.navy, .red, .printed] {
            let source = try ordinarySleeve(kind)
            let analysis = try #require(ArtworkEdgeAnalyzer.analyze(source))
            #if canImport(UIKit)
            let initial = UIImage(cgImage: source)
            #else
            let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
            #endif
            for width in [320, 390, 430] {
                let renderer = ImageRenderer(content: VStack(spacing: 0) {
                    FadedArtworkHero(coverArtId: "ordinary-\(kind.rawValue)", initialImage: initial,
                        background: analysis.fadedBackground, title: "An Ordinary Album",
                        treatment: analysis.fadedTreatment ?? .photographic, edgeColor: analysis.bottomBackground, topColor: analysis.topBackground) { artistInformationFixture }
                    analysis.fadedBackground.frame(height: 24)
                }.frame(width: CGFloat(width))
                    .environment(container.artworkImageCache).environment(\.appContainer, container))
                renderer.scale = 1
                let rendered = try #require(renderer.cgImage)
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                var bytes = [UInt8](repeating: 0, count: width * rendered.height * 4)
                let sampled = bytes.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(data: buffer.baseAddress, width: width, height: rendered.height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                    context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: rendered.height)); return true
                }
                #expect(sampled)
                let packed = try #require(analysis.packedContentBackground)
                for y in (rendered.height - 22)..<(rendered.height - 12) {
                    let i = (y * width + 2) * 4
                    #expect(abs(Int(bytes[i]) - ((packed >> 16) & 255)) <= 2)
                    #expect(abs(Int(bytes[i + 1]) - ((packed >> 8) & 255)) <= 2)
                    #expect(abs(Int(bytes[i + 2]) - (packed & 255)) <= 2)
                    #expect(bytes[i + 3] == 255)
                }
                if kind == .navy {
                    // The photographic crop keeps real lower-image content behind
                    // the heading instead of extending a thin bottom strip early.
                    let y = Int(Double(width) * (0.80 + Double(CassetteAlbumLayout.photographicHeadroom)))
                    let jacketWidth = (0..<width).filter { x in
                        let i = (y * width + x) * 4
                        return bytes[i] > 150 && bytes[i + 1] > 150 && bytes[i + 2] > 150
                    }.count
                    #expect((0.77...0.85).contains(Double(jacketWidth) / Double(width)))
                    // Added headroom is filled with the cached upper color, not
                    // a refresh gap or stretched letters from the cover.
                    for y in 0..<Int(Double(width) * Double(CassetteAlbumLayout.photographicHeadroom)) {
                        let i = (y * width + width / 2) * 4
                        #expect(abs(Int(bytes[i]) - 12) <= 2)
                        #expect(abs(Int(bytes[i + 1]) - 24) <= 2)
                        #expect(abs(Int(bytes[i + 2]) - 36) <= 2)
                        #expect(bytes[i + 3] == 255)
                    }
                }
                if kind == .printed {
                    // The new on-device comparison exposes double blur and an
                    // upward crop: preserve the original printed sleeve and white top.
                    let y = Int(Double(width) * 0.45)
                    let darkXs = (0..<width).filter { x in
                        let i = (y * width + x) * 4
                        return bytes[i] < 150 && bytes[i + 1] < 150 && bytes[i + 2] < 150
                    }
                    #expect((0.11...0.13).contains(Double(darkXs.count) / Double(width)))
                    let top = (Int(Double(width) * 0.03) * width + 2) * 4
                    #expect(bytes[top] >= 250)
                    let figure = (Int(Double(width) * 0.30) * width + width / 2) * 4
                    #expect(bytes[figure] < 30) // no gray/blur veil over the subject
                    let logo = (Int(Double(width) * 0.79) * width + width / 2) * 4
                    #expect(bytes[logo] < 60 && bytes[logo + 1] < 60)
                    // Below the real bitmap, no red lettering may be stretched or
                    // mirrored behind the heading; the continuation is neutral.
                    for y in Int(Double(width) * 0.99)..<Int(Double(width) * 1.04) {
                        let center = (y * width + width / 2) * 4
                        let edge = (y * width + 2) * 4
                        #expect(abs(Int(bytes[center]) - Int(bytes[center + 1])) <= 2)
                        #expect(abs(Int(bytes[center]) - Int(bytes[edge])) <= 3)
                        if y > Int(Double(width) * 0.99) {
                            let previous = ((y - 1) * width + 2) * 4
                            #expect(abs(Int(bytes[edge]) - Int(bytes[previous])) <= 5)
                        }
                    }
                }
                if width == 390 {
                    let url = URL(fileURLWithPath: "/tmp/cassette-1018-\(kind.rawValue)-album.png")
                    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, rendered, nil)
                    #expect(CGImageDestinationFinalize(destination))
                }
            }
        }
    }

    @Test func bottomContinuationUsesTheCentralSubjectNotSideMargins() throws {
        // A wide top field and white side margins surround a dark lower center.
        // The strip that melts into the page must follow the center, not the
        // side margins or the upper field.
        let source = try sleeve { x, y in
            if y < 24 { return 0xd01025 }
            return (20..<44).contains(x) ? 0x202022 : 0xffffff
        }
        let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
        #expect(facts.presentationStyle == .faded)
        let bottom = try #require(facts.packedBottomBackground)
        #expect(((bottom >> 16) & 255) < 80 && ((bottom >> 8) & 255) < 80 && (bottom & 255) < 80)
        let content = try #require(facts.packedContentBackground)
        #expect(((content >> 16) & 255) < 80 && ((content >> 8) & 255) < 80 && (content & 255) < 80)
    }

    @Test func mutedBottomBoundaryVetoesSaturatedInteriorTint() throws {
        for edge in [0x9baaaa, 0x969f9b, 0x969696] {
            let source = try sleeve { x, y in
                if y >= 51 { return edge }
                if y >= 30 { return (12..<52).contains(x) ? 0x205e80 : edge }
                return 0xd8e3e0
            }
            let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
            let canvas = try #require(facts.packedContentBackground)
            let channels = [(canvas >> 16) & 255, (canvas >> 8) & 255, canvas & 255]
            #expect(channels.max()! - channels.min()! <= 10)
            #expect(channels.max()! <= 58)
            #expect(facts.packedBottomBackground == edge)
            #expect(CassetteColors.meetsContrast(.white, on: facts.fadedBackground, minimum: 7))
        }
    }

    @Test func narrowBottomFieldWinsOverLargerOpposingInteriorHue() throws {
        let source = try sleeve { _, y in y >= 54 ? 0x181a4b : 0xa63a30 }
        let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
        let canvas = try #require(facts.packedContentBackground)
        let r = (canvas >> 16) & 255, g = (canvas >> 8) & 255, b = canvas & 255
        #expect(b > 2 * r && b > 2 * g)
        #expect(facts.packedBottomBackground == 0x181a4b)
    }

    @Test @MainActor func windowHeadroomMovesArtworkIndependentlyOfTheTitle() throws {
        let source = try sleeve { x, y in
            (26..<38).contains(x) && (15..<24).contains(y) ? 0xf02828 : 0x999999
        }
        #if canImport(UIKit)
        let initial = UIImage(cgImage: source)
        #else
        let initial = NSImage(cgImage: source, size: NSSize(width: 64, height: 64))
        #endif
        let width = 402
        func rows(inset: CGFloat?) throws -> (Int, Int) {
            let renderer = ImageRenderer(content: FadedArtworkHero(
                coverArtId: "window-fixture", initialImage: initial,
                background: AlbumArtworkStyle.fadedContentBackground, title: "Album Title",
                treatment: .smooth, topColor: Color(.sRGB, red: 0.6, green: 0.6, blue: 0.6),
                topInsetPoints: inset
            ) {
                Color(.sRGB, red: 0, green: 0, blue: 1).frame(height: 20)
            }.frame(width: CGFloat(width)))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
            let ctx = try #require(CGContext(data: &pixels, width: width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            let subject = try #require((0..<image.height).first { y in
                let i = (y * width + width / 2) * 4
                return pixels[i] > 180 && pixels[i + 1] < 90 && pixels[i + 2] < 90
            })
            let information = try #require((0..<image.height).first { y in
                let i = (y * width + 2) * 4
                return pixels[i + 2] > 220 && pixels[i] < 30
            })
            return (subject, information)
        }
        let fallback = try rows(inset: nil), window = try rows(inset: 59)
        // The artwork gains headroom without pushing all the text down with it.
        #expect(abs(window.0 - fallback.0 - 41) <= 2)
        #expect(abs(window.1 - fallback.1 - 35) <= 2)
    }

    @Test func topOnlyRedFieldDoesNotTintTheBottomPageColor() throws {
        // The upper red field is deliberately larger than the chromatic pieces
        // in the lower composition. The page color must still come from the
        // bottom, where the sleeve continues into the body.
        let source = try sleeve { x, y in
            if y < 26 { return 0xd01025 }
            if (14..<32).contains(x) { return 0x202022 }
            if (32..<42).contains(x) { return 0x203080 }
            if (42..<52).contains(x) { return 0x207040 }
            return 0xffffff
        }
        let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
        #expect(facts.presentationStyle == .faded)
        let content = try #require(facts.packedContentBackground)
        let r = (content >> 16) & 255, g = (content >> 8) & 255, b = content & 255
        #expect(r < 80)
        #expect(r < g || r < b)
    }

    @Test func darkSleeveBorderWinsOverWarmInterior() throws {
        for border in [0x000000, 0x141617] {
            let source = try fixture(background: border) { context in
                context.setFillColor(CGColor(red: 0.8, green: 0.45, blue: 0.12, alpha: 1))
                context.fill(CGRect(x: 7, y: 10, width: 50, height: 45))
            }
            let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
            #expect(facts.packedContentBackground == border)
            #expect(facts.packedBottomBackground == border)
            #expect(facts.packedTopBackground == border)
            let restored = try JSONDecoder().decode(ArtworkEdgeAnalysis.self, from: JSONEncoder().encode(facts))
            #expect(restored == facts)
        }
    }

    @Test func lowerCompositionOverridesUnrelatedUpperHue() throws {
        // Top/background and lower clothing can have opposing colors. These
        // synthetic sleeves test the rule without matching an album name.
        let cases: [(Int, Int)] = [
            (0xd01025, 0x181a4b), // red upper field -> navy lower canvas
            (0x36755a, 0x40281f), // green upper field -> warm brown
            (0xd0aeb7, 0x6c4a57), // pale pink portrait -> muted mauve
            (0x8b9972, 0x202022), // green lighting -> neutral shadow
            (0x254b45, 0x341923)  // teal upper field -> dark burgundy
        ]
        for (upper, lower) in cases {
            let source = try twoRegionSleeve(upper: upper, lower: lower)
            let facts = try #require(ArtworkEdgeAnalyzer.analyze(source))
            #expect(facts.presentationStyle == .faded)
            let packed = try #require(facts.packedContentBackground)
            let r = (packed >> 16) & 255, g = (packed >> 8) & 255, b = packed & 255
            switch lower {
            case 0x181a4b: #expect(b > r * 2 && b > g * 2)
            case 0x40281f: #expect(r > g && g > b)
            case 0x6c4a57: #expect(r > b && b > g && r < g * 2)
            case 0x202022: #expect(packed == lower) // Preserve the actual dark neutral border.
            default: #expect(r > b && b > g)
            }
            #expect(CassetteColors.meetsContrast(.white, on: facts.fadedBackground, minimum: 7))
            #expect(ArtworkEdgeAnalyzer.analyze(source) == facts)
        }
    }

    @Test @MainActor func doubleDMarkHasMirroredLobesAndAnOpenCenter() throws {
        let mark = DolbyDoubleDMark()
        let rect = CGRect(x: 0, y: 0, width: 145, height: 100)
        let path = mark.path(in: rect)
        #expect(path.contains(CGPoint(x: 10, y: 50)))
        #expect(path.contains(CGPoint(x: 135, y: 50)))
        #expect(!path.contains(CGPoint(x: 72, y: 50)))
        #expect(!path.contains(CGPoint(x: 60, y: 2)))
        for x in stride(from: 5, through: 140, by: 5) {
            #expect(path.contains(CGPoint(x: x, y: 25)) == path.contains(CGPoint(x: 145-x, y: 25)))
        }
        let rendered = try #require(ImageRenderer(content:
            HStack(spacing: 12) {
                AudioQualityLabelView(quality: .dolbyAtmos, foreground: .white, interactive: false, style: .album)
                AudioQualityLabelView(quality: .lossless(bitDepth: 16, sampleRate: 44100, formatLabel: "FLAC"), foreground: .white, interactive: false, style: .album)
            }.padding(20).background(Color.black)).cgImage)
        let url = URL(fileURLWithPath: "/tmp/cassette-1018-audio-marks.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rendered, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func sleeve(_ color: (_ x: Int, _ y: Int) -> Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let packed = color(x, y)
                let i = (y * 64 + x) * 4
                bytes[i] = UInt8((packed >> 16) & 255)
                bytes[i + 1] = UInt8((packed >> 8) & 255)
                bytes[i + 2] = UInt8(packed & 255)
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func twoRegionSleeve(upper: Int, lower: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let color = y < 39 ? upper : lower
                let i = (y * 64 + x) * 4
                bytes[i] = UInt8((color >> 16) & 255)
                bytes[i + 1] = UInt8((color >> 8) & 255)
                bytes[i + 2] = UInt8(color & 255)
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private enum OrdinarySleeve: String { case navy, red, printed }

    /// Synthetic composition fixtures, without album names or reference screenshot
    /// pixels baked into the classifier. CGImage rows are explicitly top-to-bottom.
    private func ordinarySleeve(_ kind: OrdinarySleeve) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let rgb: (UInt8, UInt8, UInt8)
                switch kind {
                case .navy:
                    if x > 12 && x < 52 && y > 35 { rgb = (220, 222, 215) }
                    else if x > 36 && x < 52 && y > 12 && y < 32 { rgb = (173, 127, 88) }
                    else { rgb = (12, 24, 36) }
                case .red:
                    if (9..<23).contains(y) || y > 53 {
                        let v: UInt8 = ((x / 8) % 2 == 0) ? 15 : 220
                        rgb = (v, v, v)
                    } else { rgb = (166, 67, 59) }
                case .printed:
                    if (28..<36).contains(x) && (10..<43).contains(y) { rgb = (18, 18, 18) }
                    else if (22..<42).contains(x) && (48..<54).contains(y) { rgb = (15, 15, 15) }
                    else if (22..<42).contains(x) && (55..<59).contains(y) { rgb = (160, 20, 35) }
                    else { rgb = (255, 255, 255) }
                }
                let i = (y * 64 + x) * 4
                bytes[i] = rgb.0; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.2
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func nonSquareScansUseTheOriginalCardAutomatically() throws {
        let square = try fixture(background: 0xffffff)
        let rectangle = try #require(square.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 40)))
        let facts = try #require(ArtworkEdgeAnalyzer.analyze(rectangle))
        #expect(AlbumArtworkPreference.automatic.style(analysis: facts) == .standard)
    }

    @Test @MainActor func oldPreparedFactsUpgradeFromLocalArtwork() async throws {
        let container = try AppContainer(inMemory: true)
        let id = "migration-\(UUID())"
        let image = try fixture(background: 0x303030)
        var legacy = AlbumColorAnalyzer.generateArtworkPalette(from: image)
        legacy.edgeAnalysis = ArtworkEdgeAnalysis(version: 7, packedBackground: 0,
            uniformity: 1, matchingCorners: 4, isOpaque: true, isSeamless: true,
            fingerprint: 1, presentationStyle: .faded)
        container.artworkImageCache.storePreparedPalette(legacy, for: id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(await AlbumCoverPreloadService.prepareTheme(for: id,
            artworkImageCache: container.artworkImageCache, dominantColorExtractor: nil, originalURL: url))
        let prepared = try #require(container.artworkImageCache.preparedPalette(for: id)?.edgeAnalysis)
        #expect(prepared.version == ArtworkEdgeAnalysis.currentVersion)
        #expect(prepared.packedTopBackground == 0x303030)
        #expect(prepared.packedBottomBackground == 0x303030)
        // An interrupted/current-format cache can have a new version but no
        // endpoints. It must be repaired too, rather than skipped as already current.
        legacy.edgeAnalysis = ArtworkEdgeAnalysis(version: ArtworkEdgeAnalysis.currentVersion, packedBackground: 0,
            uniformity: 1, matchingCorners: 4, isOpaque: true, isSeamless: true,
            fingerprint: 1, presentationStyle: .faded)
        container.artworkImageCache.storePreparedPalette(legacy, for: id)
        #expect(await AlbumCoverPreloadService.prepareTheme(for: id,
            artworkImageCache: container.artworkImageCache, dominantColorExtractor: nil, originalURL: url))
        #expect(container.artworkImageCache.preparedPalette(for: id)?.edgeAnalysis?.isPreparedForCurrentPresentation == true)
        await container.artworkImageCache.invalidate(for: id)
    }

    @Test func oldAnalysisDecodesButWaitsForPreparationBeforeChoosingALayout() throws {
        let json = Data("""
            {"version":2,"packedBackground":10066329,"uniformity":1,"matchingCorners":4,
             "isOpaque":true,"isSeamless":true,"fingerprint":42}
            """.utf8)
        let old = try JSONDecoder().decode(ArtworkEdgeAnalysis.self, from: json)
        #expect(old.presentationStyle == nil)
        #expect(AlbumArtworkPreference.automatic.style(analysis: old) == .standard)
    }

    @Test func transparentCenterOrEdgesCannotMasqueradeAsBlackSleeves() throws {
        for hole in [CGRect(x: 0, y: 0, width: 64, height: 4), CGRect(x: 24, y: 24, width: 16, height: 16)] {
            let image = try fixture(background: 0x000000) { $0.clear(hole) }
            let analysis = try #require(ArtworkEdgeAnalyzer.analyze(image))
            #expect(!analysis.isOpaque)
            #expect(!analysis.isSeamless)
            #expect(!AlbumArtworkPreference.fullBleed.usesFullBleed(analysis: analysis))
        }
    }

    @Test func minorWhiteCompressionNoiseIsAcceptedButDoesNotBecomeSystemGray() throws {
        let image = try fixture(background: 0xfefefe) { context in
            for y in 0..<64 {
                for x in 0..<64 where (x + y).isMultiple(of: 3) {
                    context.setFillColor(CGColor(gray: 253.0 / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let analysis = try #require(ArtworkEdgeAnalyzer.analyze(image))
        #expect(analysis.isSeamless)
        #expect(analysis.packedBackground == 0xfefefe)
        #expect(!AlbumArtworkPreference.card.usesFullBleed(analysis: analysis))
        #expect(!AlbumArtworkPreference.automatic.usesFullBleed(analysis: nil))
    }

    @Test func legacyPaletteDecodesAndNewFactsRoundTripWithoutLoss() throws {
        let legacy = Data("{\"packedBackground\":16711422,\"packedText1\":0,\"packedText2\":1,\"packedText3\":2,\"packedText4\":3}".utf8)
        var palette = try JSONDecoder().decode(ColorCache.CachedPalette.self, from: legacy)
        #expect(palette.edgeAnalysis == nil)
        let white = try fixture(background: 0xfefefe)
        let changed = try fixture(background: 0xfefefe) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 22, y: 22, width: 20, height: 20))
        }
        let analysis = try #require(ArtworkEdgeAnalyzer.analyze(white))
        #expect(analysis.fingerprint == ArtworkEdgeAnalyzer.analyze(white)?.fingerprint)
        #expect(analysis.fingerprint != ArtworkEdgeAnalyzer.analyze(changed)?.fingerprint)
        palette.edgeAnalysis = analysis
        let restored = try JSONDecoder().decode(ColorCache.CachedPalette.self, from: JSONEncoder().encode(palette))
        #expect(restored == palette)
        #expect(restored.asArtworkPalette().edgeAnalysis == analysis)
    }

    @Test func removingAnArtworkInvalidatesOnlyItsPersistedFacts() async throws {
        let writes = Mutex<[[String: Data]]>([])
        let palette = ColorCache.CachedPalette(packedBackground: 0xffffff, packedText1: 0,
                                               packedText2: 0, packedText3: 0, packedText4: 0)
        let data = try JSONEncoder().encode(palette)
        let cache = ArtworkPaletteCache(load: { ["changed": data, "retained": data] },
                                       persist: { snapshot in writes.withLock { $0.append(snapshot) } })
        cache.remove(for: "changed")
        #expect(cache.palette(for: "changed") == nil)
        #expect(cache.palette(for: "retained") == palette)
        await cache.flush()
        #expect(writes.withLock { $0.last?.keys.sorted() } == ["retained"])
    }

    private func fixture(background: Int, draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let color = try #require(CGColor(colorSpace: colorSpace, components: [
            Double((background >> 16) & 255) / 255,
            Double((background >> 8) & 255) / 255, Double(background & 255) / 255, 1]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        draw(context)
        return try #require(context.makeImage())
    }
}
