import CoreGraphics
import SwiftUI
import Testing
@testable import Cassette

@Suite("Phone landscape player")
@MainActor
struct PhoneLandscapePlayerTests {
    @Test func artworkAndControlsStaySeparateAcrossPhoneViewports() throws {
        // Full-screen sizes. The reference margins keep the columns clear of
        // landscape camera cutouts and leave room for 44pt tap targets.
        for size in [CGSize(width: 568, height: 320), CGSize(width: 724, height: 354),
                     CGSize(width: 780, height: 369), CGSize(width: 874, height: 410)] {
            let renderer = ImageRenderer(content:
                PhoneLandscapePlayerColumns {
                    Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
                } controls: {
                    Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1).frame(minWidth: 180)
                }
                .frame(width: size.width, height: size.height)
            )
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(origin: .zero, size: size))
            var red = CGRect.null, blue = CGRect.null
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if pixels[i] > 200 && pixels[i + 2] < 20 {
                        red = red.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                    if pixels[i + 2] > 200 && pixels[i] < 20 {
                        blue = blue.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            #expect(!red.isNull && !blue.isNull)
            #expect(abs(red.width - red.height) <= 1)
            #expect(blue.minX - red.maxX >= 23)
            #expect(red.minX >= 23 && blue.maxX <= size.width - 23)
            #expect(blue.width >= 180)
            #expect(red.minY > 0 && red.maxY < size.height)
        }
    }
}
