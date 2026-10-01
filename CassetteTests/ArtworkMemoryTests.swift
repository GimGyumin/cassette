import Foundation
import CoreGraphics
import ImageIO
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Testing
@testable import Cassette

@Suite("ArtworkMemory")
struct ArtworkMemoryTests {
    private func largeJPEG() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 2400, height: 1600,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    @Test("Large covers are decoded to their display tier, with pixel-based memory accounting")
    func boundedDecode() throws {
        let data = try largeJPEG()
        for tier in [ArtworkTier.thumb, .hero] {
            let image = try #require(ArtworkImageCache.thumbnailImage(from: data, maxDimension: tier.decodePixels))
            #expect(image.size.width == CGFloat(tier.decodePixels))
            #expect(image.size.height == CGFloat(tier.decodePixels * 2 / 3))
            #expect(image.decodedMemoryCost <= tier.decodePixels * tier.decodePixels * 4)
            #expect(image.decodedMemoryCost >= Int(image.size.width * image.size.height) * 4)
        }
    }

    @Test("Lock-screen artwork shares a bounded image and reloads after a memory purge")
    func lockScreenCacheAndPurge() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try largeJPEG().write(to: url)
        let loader = ArtworkLoader()
        let first = try #require(await loader.artwork(for: url, headers: [:]))
        let second = try #require(await loader.artwork(for: url, headers: [:]))
        #expect(first === second)
        #expect(first.bounds.size.width == CGFloat(ArtworkTier.hero.decodePixels))
        #expect(first.bounds.size.height == 800)
        let watchImage = try #require(first.image(at: CGSize(width: 150, height: 100)))
        #expect(watchImage.size.width == 150)
        #expect(watchImage.size.height == 100)
        let wideRequest = try #require(first.image(at: CGSize(width: 150, height: 50)))
        #expect(wideRequest.size.width <= 150)
        #expect(wideRequest.size.height <= 50)
        await loader.clearCache()
        let reloaded = try #require(await loader.artwork(for: url, headers: [:]))
        #expect(reloaded !== first)
        #expect(reloaded.bounds == first.bounds)
    }
}
