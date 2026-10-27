// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import ImageIO
import SwiftUI
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Cassette

@MainActor
@Suite("Immersive player reference")
struct ImmersivePlayerLayoutTests {
    @Test func measuredReferenceRowsAndInsets() throws {
        let size = CGSize(width: 402, height: 874)
        let image = try render(ImmersivePlayerControlsLayout {
            Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
            Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)
            Color.blue; Color.purple; Color.yellow
        }.frame(width: size.width, height: size.height))
        let pixels = try rgba(image)
        let info = bounds(pixels, width: image.width, height: image.height) { $0 > 230 && $1 < 20 && $2 < 20 }
        let seek = bounds(pixels, width: image.width, height: image.height) { $1 > 230 && $0 < 20 && $2 < 20 }
        #expect(abs(info.minX - 32) <= 1)
        #expect(abs(info.minY - 496) <= 2)
        #expect(abs(seek.minX - 32) <= 1)
        #expect(abs(seek.minY - 565) <= 2)
        #expect(info.maxY < seek.minY)
    }

    @Test func smallerPhonesKeepAllControlsSeparate() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 390, height: 844), CGSize(width: 402, height: 874), CGSize(width: 430, height: 932)] {
            let m = ImmersivePlayerMetrics(size: size, topInset: 59)
            #expect(m.infoTop + 48 < m.scrubberTop)
            #expect(m.scrubberTop + 40 < m.transportCenter - 44)
            #expect(m.transportCenter + 44 < m.volumeCenter - 18)
            #expect(m.volumeCenter + 18 < m.footerCenter - 27)
            #expect(m.footerCenter + 32 < size.height)
        }
    }

    @Test func edgeExtensionDoesNotSmearCenterColorsAndControlsStayDark() throws {
        for gray in [CGFloat(0.60), CGFloat(1.0)] {
            let sleeve = try makeSleeve(gray: gray)
            let size = CGSize(width: 402, height: 874)
            let metric = ImmersivePlayerMetrics(size: size, topInset: 62)
            let channel = Int(gray * 255)
            let rgb = channel << 16 | channel << 8 | channel
            let background = ImmersiveNowPlayingBackground(coverArtId: "fixture", initialImage: sleeve,
                fallbackColor: .gray, metrics: metric, lowerEdgeRGB: rgb)
            let image = try render(background.frame(width: size.width, height: size.height))
            let pixels = try rgba(image)
            for y in [Int(metric.infoTop), 650, 820] {
                let i = (y * image.width + image.width / 2) * 4
                #expect(abs(Int(pixels[i]) - Int(pixels[i + 2])) < 4)
                #expect(pixels[i] < 125)
            }
            let title = Int(metric.infoTop) * image.width * 4
            let footer = 820 * image.width * 4
            #expect(pixels[footer] < pixels[title])
            if gray < 1 {
                try save(image, name: "cassette-1029-immersive-background.png")
            }
        }
    }

    @Test func footerKeepsTheSameSlotAcrossAllPortraitSurfaces() throws {
        let state = PlayerState()
        var frames: [CGRect] = []
        for surface in [PlayerSurface.player, .lyrics, .queue] {
            let image = try render(PortraitPlayerFooterLayout(topInset: 62, bottomInset: 34) {
                BottomToolbar(surface: .constant(surface), isLiveStream: false,
                    contentColor: .white, secondaryContentColor: .white, playerState: state, phonePortrait: true)
                    .background(Color(.sRGB, red: 1, green: 0, blue: 0))
            }.frame(width: 402, height: 778).buttonStyle(.plain))
            let pixels = try rgba(image)
            frames.append(bounds(pixels, width: image.width, height: image.height) { $0 > 240 && $1 < 10 && $2 < 10 })
        }
        #expect(frames[0] == frames[1] && frames[1] == frames[2])
        #expect(abs(frames[0].minX - 24) <= 1)
        #expect(abs(frames[0].height - 54) <= 1)
        #expect(abs(frames[0].midY - (min(874 * 0.925, 874 - 34 - 40) - 62)) <= 1)
    }

    @Test func lowerArtworkHandoffHasNoVisibleScanline() throws {
        let size = CGSize(width: 402, height: 874)
        let metric = ImmersivePlayerMetrics(size: size, topInset: 62)
        for gray in [CGFloat(0.60), CGFloat(1)] {
            let sleeve = try makeSleeve(gray: gray)
            let channel = Int(gray * 255)
            let rgb = channel << 16 | channel << 8 | channel
            let image = try render(ImmersiveNowPlayingBackground(coverArtId: "handoff", initialImage: sleeve,
                fallbackColor: .black, metrics: metric, lowerEdgeRGB: rgb))
            let pixels = try rgba(image)
            let start = Int(metric.artworkTop + size.width * 0.92)
            let end = Int(metric.infoTop + 40)
            for x in [10, 200, 390] {
                for y in (start + 1)..<end {
                    let index = (y * image.width + x) * 4
                    let previous = index - image.width * 4
                    #expect(abs(Int(pixels[index]) - Int(pixels[previous])) <= 3)
                    #expect(pixels[index + 3] == 255)
                }
            }
        }
    }

    @Test func lowerChromeDoesNotMoveWhenPanelExpandsOrChangesSurface() throws {
        let size = CGSize(width: 402, height: 874)
        var chromeBounds: [[CGRect]] = []
        for surface in [PlayerSurface.player, .lyrics, .queue] {
            let image = try render(ImmersivePlayerControlsLayout(topInset: 62, bottomInset: 34,
                expandedPanel: surface == .lyrics) {
                Color.clear
                Color(.sRGB, red: 1, green: 0, blue: 0)
                Color(.sRGB, red: 0, green: 1, blue: 0)
                Color(.sRGB, red: 0, green: 0, blue: 1)
                Color(.sRGB, red: 1, green: 1, blue: 0)
                Color.clear
            }.frame(width: size.width, height: size.height))
            let pixels = try rgba(image)
            chromeBounds.append([
                bounds(pixels, width: image.width, height: image.height) { $0 > 240 && $1 < 10 && $2 < 10 },
                bounds(pixels, width: image.width, height: image.height) { $1 > 240 && $0 < 10 && $2 < 10 },
                bounds(pixels, width: image.width, height: image.height) { $2 > 240 && $0 < 10 && $1 < 10 },
                bounds(pixels, width: image.width, height: image.height) { $0 > 240 && $1 > 240 && $2 < 10 }
            ])
        }
        #expect(chromeBounds[0] == chromeBounds[1] && chromeBounds[1] == chromeBounds[2])
        for size in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 430, height: 932)] {
            let metrics = ImmersivePlayerMetrics(size: size, topInset: 62, bottomInset: 34)
            // Route-name label extends below the glyph; keep all of it above the home area.
            #expect(metrics.footerCenter + 32 <= size.height - 34 - 8)
            #expect(metrics.volumeCenter + 18 < metrics.footerCenter - 27)
        }
    }

    @Test func hiddenChromeReleasesTheWholeLowerLyricsViewport() throws {
        let image = try render(ImmersivePlayerControlsLayout(topInset: 62, bottomInset: 34, expandedPanel: true) {
            Color.clear; Color.clear; Color.clear; Color.clear; Color.clear
            Color(.sRGB, red: 0, green: 1, blue: 0)
        }.frame(width: 402, height: 874))
        let pixels = try rgba(image)
        let panel = bounds(pixels, width: image.width, height: image.height) { $1 > 230 && $0 < 20 && $2 < 20 }
        #expect(abs(panel.maxY - (874 - 34 - 8)) <= 1)
        #expect(abs(panel.minY - (62 + 34)) <= 1)
    }

    @Test func handleHasOneFixedCapsuleAndNoHairlineShadow() throws {
        let image = try render(PlayerDismissHandle(contentColor: .white, action: {})
            .frame(width: 402, height: 60).background(.black))
        let pixels = try rgba(image)
        let grip = bounds(pixels, width: image.width, height: image.height) { $0 > 30 && $1 > 30 && $2 > 30 }
        #expect(abs(grip.width - 60) <= 1 && abs(grip.height - 4) <= 1)
    }

    @Test func upperArtworkJoinsTheExtendedStatusAreaWithoutAHardLine() throws {
        let width = 200
        var bytes = [UInt8](repeating: 255, count: width * width * 4)
        for y in 0..<width {
            let value = UInt8(y < 10 ? 220 - y * 8 : 140)
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try #require(CGImage(width: width, height: width, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        #if canImport(UIKit)
        let sleeve = UIImage(cgImage: cg)
        #else
        let sleeve = NSImage(cgImage: cg, size: CGSize(width: width, height: width))
        #endif
        let size = CGSize(width: 402, height: 874)
        let metric = ImmersivePlayerMetrics(size: size, topInset: 62)
        let image = try render(ImmersiveNowPlayingBackground(coverArtId: "upper", initialImage: sleeve,
            fallbackColor: .black, metrics: metric, lowerEdgeRGB: 0x8c8c8c))
        let pixels = try rgba(image)
        for y in (Int(metric.artworkTop) - 6)...(Int(metric.artworkTop) + 6) {
            let index = (y * image.width + 100) * 4
            #expect(abs(Int(pixels[index]) - Int(pixels[index - image.width * 4])) <= 6)
            #expect(pixels[index + 3] == 255)
        }
    }

    @Test func renderReferenceChromeFixture() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Fixture", baseURL: "https://example.invalid", username: "fixture"))
        let state = PlayerState()
        state.currentTrack = DisplayableSong(id: "fixture", title: "Wanna Be Startin’ Somethin’",
            artist: "Michael Jackson", duration: 363)
        state.position = 77
        state.duration = 363
        let size = CGSize(width: 402, height: 874)
        let metrics = ImmersivePlayerMetrics(size: size, topInset: 62)
        let sleeve = try makeSleeve(gray: 0.6)
        let scene = ImmersivePlayerControlsLayout {
            TrackInfoSection(playerState: state, container: container,
                contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.artist,
                glassTint: .clear, layout: .immersivePortrait)
            VStack(spacing: 0) {
                ProgressSlider(value: .constant(77), total: 363, onEditingChanged: { _ in }, height: 18, trackHeight: 7)
                ScrubberTimeLabels(playerState: state, effectiveDuration: 363, overridePosition: nil,
                    color: ImmersivePlayerInk.timing, qualityColor: ImmersivePlayerInk.quality,
                    quality: .lossless(bitDepth: 16, sampleRate: 44100, formatLabel: "FLAC"),
                    showsRemainingMinus: true, compactQualityChip: true)
            }
            PlaybackControlsView(playerState: state, playerService: nil, contentColor: .white,
                secondaryContentColor: ImmersivePlayerInk.controls, spreadsTransport: true, phonePortraitControls: true)
            HStack {
                Image(systemName: "speaker.fill")
                ProgressSlider(value: .constant(0.2), total: 1, onEditingChanged: { _ in }, height: 36, trackHeight: 6)
                Image(systemName: "speaker.wave.3.fill")
            }.font(.system(size: 12)).foregroundStyle(ImmersivePlayerInk.controls)
            HStack {
                Image(systemName: "quote.bubble").frame(maxWidth: .infinity)
                Image(systemName: "airpods").frame(maxWidth: .infinity)
                Image(systemName: "list.bullet").frame(maxWidth: .infinity)
            }.font(.system(size: 20)).foregroundStyle(ImmersivePlayerInk.controls)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .background(ImmersiveNowPlayingBackground(coverArtId: "fixture", initialImage: sleeve,
            fallbackColor: .gray, metrics: metrics, lowerEdgeRGB: 0x999999))
        .environment(\.colorScheme, .dark)
        .buttonStyle(.plain)
        .environment(container.artworkImageCache)
        .environment(\.appContainer, container)
        .modelContainer(container.modelContainer)
        try save(try render(scene), name: "cassette-1029-immersive-layout.png")
    }

    private func makeSleeve(gray: CGFloat) throws -> PlatformImage {
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
            bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 90, y: 70, width: 80, height: 90))
        let image = try #require(context.makeImage())
        #if canImport(UIKit)
        return UIImage(cgImage: image)
        #else
        return NSImage(cgImage: image, size: CGSize(width: 200, height: 200))
        #endif
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func bounds(_ pixels: [UInt8], width: Int, height: Int, matches: (UInt8, UInt8, UInt8) -> Bool) -> CGRect {
        var result = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if matches(pixels[i], pixels[i + 1], pixels[i + 2]) { result = result.union(CGRect(x: x, y: y, width: 1, height: 1)) }
            }
        }
        return result
    }

    private func save(_ image: CGImage, name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
