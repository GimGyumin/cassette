import Testing
import SwiftUI
import CoreGraphics
import ImageIO
@testable import Cassette

@Suite("Album related shelf background")
struct AlbumRelatedShelfBackgroundTests {
    @Test(arguments: [-999, -100, 80, 360, 700])
    @MainActor func shelfColorContinuesThroughReservedBottomSpace(start: Int) throws {
        let base = Color(.sRGB, red: 0.35, green: 0.23, blue: 0.10)
        let size = CGSize(width: 320, height: 640)
        let fixture = ZStack(alignment: .top) {
            Color.clear
            if start != -999 {
                AlbumRelatedShelfFill(baseColor: base)
                    .frame(height: 140)
                    .anchorPreference(key: AlbumRelatedShelfBoundsKey.self, value: .bounds) { $0 }
                    .offset(y: CGFloat(start))
            }
        }
        .backgroundPreferenceValue(AlbumRelatedShelfBoundsKey.self) { anchor in
            ZStack {
                base
                AlbumRelatedShelfContinuation(anchor: anchor, baseColor: base)
            }
        }
        // The system reserves real space for the mini player and tab bar outside
        // the scrolling shelf. Painting only the shelf leaves this strip brighter.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 120) }
        .frame(width: size.width, height: size.height)
        .background(base)
        let image = try #require(ImageRenderer(content: fixture).cgImage)
        let reference = try #require(ImageRenderer(content:
            VStack(spacing: 0) {
                base.frame(height: 1)
                AlbumRelatedShelfFill(baseColor: base).frame(height: 1)
            }.frame(width: 1)).cgImage)
        func bytes(_ image: CGImage) throws -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &result, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return result
        }
        let actual = try bytes(image), colors = try bytes(reference)
        #expect(image.width == 320 && image.height == 640)
        for y in [20, 100, 400, 510, 530, 600, 638] {
            let dark = start != -999 && y >= max(0, start)
            for channel in 0..<3 {
                let expected = Int(colors[(dark ? 4 : 0) + channel])
                let value = Int(actual[(y * image.width + 10) * 4 + channel])
                #expect(abs(value - expected) <= 1, "Shelf start \(start), screen row \(y)")
            }
        }
        if start == 360 {
            let url = URL(fileURLWithPath: "/tmp/cassette-album-shelf-bottom.png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }
}
