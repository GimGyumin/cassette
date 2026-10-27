import CoreGraphics
import SwiftUI
import Testing
@testable import Cassette

@Suite("Landscape quality label")
@MainActor
struct LandscapeQualityLabelTests {
    @Test func losslessMarkRemainsVisibleBetweenLandscapeTimeLabels() throws {
        for width in [CGFloat(204), CGFloat(380)] {
            let renderer = ImageRenderer(content: ScrubberTimeLabels(
                playerState: PlayerState(), effectiveDuration: 240, overridePosition: nil,
                color: .white, qualityColor: Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1),
                quality: .lossless(bitDepth: 16, sampleRate: 44100, formatLabel: "FLAC"), showsRemainingMinus: true
            ).frame(width: width, height: 40).background(.black))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var qualityInk = 0
            for y in 0..<image.height {
                for x in (image.width / 4)..<(image.width * 3 / 4) {
                    let index = (y * image.width + x) * 4
                    if pixels[index + 1] > 120 && pixels[index] < 80 && pixels[index + 2] < 80 {
                        qualityInk += 1
                    }
                }
            }
            #expect(qualityInk > 10)
        }
    }
}
