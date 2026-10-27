import AVFoundation
import CoreGraphics
import Testing
@testable import Cassette

@Suite("Immersive artwork asset")
struct ImmersiveArtworkVideoTests {
    @Test func tallAssetIsLocalDecodableAndReused() async throws {
        let context = try #require(CGContext(data: nil, width: 600, height: 800,
            bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        let source = try #require(context.makeImage())
        let video = StillArtworkVideo(image: source)
        let url = try #require(await video.fileURL())
        #expect(url.isFileURL)
        #expect(await video.fileURL() == url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 600, height: 800))
        #expect(try await asset.load(.duration).seconds == 2)
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: .zero).image
        #expect(frame.width == 600 && frame.height == 800)
        // Keep the asset owner alive until decoding finishes: the system callbacks
        // retain the same owner for the lifetime of published artwork.
        #expect(await video.fileURL() == url)
    }
}
