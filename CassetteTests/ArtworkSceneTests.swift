import Testing
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Cassette

@Suite("Artwork scene")
struct ArtworkSceneTests {
    @Test("Decoration time freezes while paused or hidden and resumes without a jump")
    func clockFreezes() {
        var clock = ArtworkSceneClock()
        clock.setRunning(true, now: 10)
        #expect(clock.sample(now: 12) == 2)
        clock.setRunning(false, now: 13)
        #expect(clock.sample(now: 200) == 3)
        clock.setRunning(true, now: 250)
        #expect(clock.sample(now: 251) == 4)
    }

    @Test("Only the background is downsampled, retaining its aspect ratio")
    func renderBudget() {
        let size = ArtworkSceneMotion.renderSize(for: CGSize(width: 1290, height: 2796))
        #expect(size.height == 384)
        #expect(abs(Double(size.width) / Double(size.height) - 1290.0 / 2796.0) < 0.003)
        let zero = ArtworkSceneMotion.renderSize(for: .zero)
        #expect(zero.width == 1 && zero.height == 1)
        let invalid = ArtworkSceneMotion.renderSize(for: CGSize(width: CGFloat.infinity, height: 10))
        #expect(invalid.width == 1 && invalid.height == 1)
    }

    @Test("Playing bars have different phases and stop changing when paused")
    func barsFollowState() {
        for index in 0..<4 {
            #expect(ArtworkSceneMotion.barHeight(index: index, elapsed: 0, animated: false)
                == ArtworkSceneMotion.barHeight(index: index, elapsed: 100, animated: false))
            for time in stride(from: 0.0, to: 10, by: 0.13) {
                let height = ArtworkSceneMotion.barHeight(index: index, elapsed: time, animated: true)
                #expect(height >= 3 && height <= 14)
            }
        }
        let heights = (0..<4).map { ArtworkSceneMotion.barHeight(index: $0, elapsed: 0, animated: true) }
        #expect(Set(heights).count == 4)
        #expect(ArtworkSceneMotion.crossfadeProgress(elapsed: -1) == 0)
        #expect(ArtworkSceneMotion.crossfadeProgress(elapsed: 0.6) == 0.5)
        #expect(ArtworkSceneMotion.crossfadeProgress(elapsed: 10) == 1)
    }

    @Test("Real Metal rendering evolves without audio and is deterministic at a fixed time")
    func gpuMotion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricsArtworkGPU(device: device)
        let texture = try artwork(device: device, colors: [
            SIMD4<UInt8>(20, 70, 230, 255), SIMD4<UInt8>(220, 30, 55, 255),
            SIMD4<UInt8>(235, 180, 20, 255), SIMD4<UInt8>(100, 35, 200, 255)
        ])
        gpu.replaceArtwork(texture, crossfade: false)
        let first = try pixels(gpu: gpu, time: 0)
        let repeated = try pixels(gpu: gpu, time: 0)
        let later = try pixels(gpu: gpu, time: 90)
        #expect(distance(first, repeated) < 0.0001)
        #expect(distance(first, later) > 0.003)
        #expect(first.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        try writePreview(first, name: "cassette-lyrics-scene-0.png")
        try writePreview(later, name: "cassette-lyrics-scene-90.png")
    }

    @Test("Rapid artwork changes fade from the visible composite, including an unfinished fade")
    func interruptedCrossfade() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricsArtworkGPU(device: device)
        gpu.replaceArtwork(try artwork(device: device, colors: [SIMD4<UInt8>(240, 25, 30, 255)]), crossfade: false)
        let red = try pixels(gpu: gpu, time: 0)
        #expect(gpu.replaceArtwork(try artwork(device: device, colors: [SIMD4<UInt8>(20, 30, 240, 255)]), crossfade: true))
        #expect(distance(red, try pixels(gpu: gpu, time: 0, fade: 0)) < 0.001)
        let half = try pixels(gpu: gpu, time: 0, fade: 0.5)
        #expect(distance(red, half) > 0.01)
        #expect(gpu.replaceArtwork(try artwork(device: device, colors: [SIMD4<UInt8>(20, 230, 30, 255)]), crossfade: true))
        #expect(distance(half, try pixels(gpu: gpu, time: 0, fade: 0)) < 0.001)
        let green = try pixels(gpu: gpu, time: 0, fade: 1)
        #expect(distance(half, green) > 0.01)
    }

    @Test("Adaptive statistics preserve a neutral cover and ignore transparent RGB")
    func colorStatistics() {
        let profile = ArtworkSceneColorProfile.analyze(rgba: [128, 128, 128, 255, 255, 0, 0, 0], width: 2, height: 1)
        #expect(abs(profile.average.x - ArtworkSceneColorProfile.decode(128 / 255)) < 0.0001)
        #expect(profile.average.x == profile.average.y && profile.average.y == profile.average.z)
        #expect(profile.distribution.z == 0)
        #expect(profile.distribution.x == profile.distribution.y)
        let empty = ArtworkSceneColorProfile.analyze(rgba: [255, 0, 0, 0], width: 1, height: 1)
        #expect(empty.average == .zero)
    }

    @Test("Colored artwork regions resist dilution by neutral subjects without prescribing a hue")
    func chromaticAnchor() {
        let profile = ArtworkSceneColorProfile.analyze(rgba: [220, 160, 50, 255, 100, 100, 100, 255], width: 2, height: 1)
        #expect(profile.colorAnchor.w == 1)
        #expect(profile.colorAnchor.x / profile.colorAnchor.y > profile.average.x / profile.average.y)
        let neutral = ArtworkSceneColorProfile.analyze(rgba: [128, 128, 128, 255], width: 1, height: 1)
        #expect(abs(neutral.colorAnchor.x - neutral.average.x) < 0.0001)
        #expect(neutral.colorAnchor.x == neutral.colorAnchor.y)
    }

    @Test("Bright, dark and monochrome covers remain smooth, neutral and readable", arguments: [UInt8(8), 128, 255])
    func neutralCovers(level: UInt8) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try LyricsArtworkGPU(device: device)
        let color = SIMD4<UInt8>(level, level, level, 255)
        let profile = ArtworkSceneColorProfile.analyze(rgba: [level, level, level, 255], width: 1, height: 1)
        let texture = try artwork(device: device, colors: [color])
        gpu.replaceArtwork(texture, profile: profile, crossfade: false)
        let result = try pixels(gpu: gpu, time: 0)
        var light: [Float] = []
        for i in stride(from: 0, to: result.count, by: 256) {
            #expect(abs(result[i] - result[i + 1]) < 0.0005)
            #expect(abs(result[i + 1] - result[i + 2]) < 0.0005)
            #expect(result[i + 3] == 1)
            light.append(result[i])
        }
        let darkest = try #require(light.min()), brightest = try #require(light.max())
        #expect(brightest <= 0.165) // White lyric contrast exceeds 4.5:1 even on a white cover.
        #expect(darkest >= brightest * 0.94) // No artificial bottom black gradient.
        #expect(!gpu.replaceArtwork(texture, profile: profile, crossfade: true))
        try writePreview(result, name: "cassette-lyrics-neutral-\(level).png")
    }

    @MainActor
    @Test("Player and lyrics share one cached color-managed texture")
    func textureReuse() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.65, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let cg = try #require(context.makeImage())
        #if os(iOS)
        let image = UIImage(cgImage: cg)
        #else
        let image = NSImage(cgImage: cg, size: CGSize(width: 16, height: 16))
        #endif
        let cache = ArtworkSceneTextureCache()
        async let firstRequest = cache.artwork(image: image, device: device)
        async let secondRequest = cache.artwork(image: image, device: device)
        let first = try #require(await firstRequest)
        let second = try #require(await secondRequest)
        #expect(first.texture === second.texture)
        #expect(first.texture.pixelFormat == .rgba8Unorm_srgb)
        let third = try #require(await cache.artwork(image: image, device: device))
        #expect(first.texture === third.texture)
        let cancelled = Task { () -> PreparedArtworkScene? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.artwork(image: image, device: device)
        }
        #expect(await cancelled.value == nil)
    }

    @MainActor
    @Test("Optional real album preview uses the production color-managed preparation")
    func realAlbumPreview() throws {
        let url = URL(fileURLWithPath: "/tmp/cassette-xscape-cover.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Real Xscape artwork unavailable; synthetic cover checks still run.")
            return
        }
        #if os(iOS)
        let image = try #require(UIImage(contentsOfFile: url.path))
        #else
        let image = try #require(NSImage(contentsOf: url))
        #endif
        let device = try #require(MTLCreateSystemDefaultDevice())
        let prepared = try #require(PreparedArtworkScene.prepare(image: image, device: device))
        let gpu = try LyricsArtworkGPU(device: device)
        gpu.replaceArtwork(prepared.texture, profile: prepared.profile, crossfade: false)
        print("Xscape linear P3 profile: \(prepared.profile)")
        for time: Float in [0, 30, 90] {
            let output = try pixels(gpu: gpu, time: time)
            #expect(output.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
            try writePreview(output, name: "cassette-xscape-scene-\(Int(time)).png")
        }
    }

    private func artwork(device: any MTLDevice, colors: [SIMD4<UInt8>]) throws -> any MTLTexture {
        let dimension = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: dimension, height: dimension, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
        for y in 0..<dimension {
            for x in 0..<dimension {
                let color = colors[(x / 64 + (y / 64) * 2) % colors.count]
                for channel in 0..<4 { bytes[(y * dimension + x) * 4 + channel] = color[channel] }
            }
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, dimension, dimension), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: dimension * 4)
        }
        return texture
    }

    private func pixels(gpu: LyricsArtworkGPU, time: Float, fade: Float = 1) throws -> [Float] {
        let frame = try #require(gpu.render(size: CGSize(width: 192, height: 384), elapsed: time, transition: fade))
        let row = frame.texture.width * 8
        let buffer = try #require(gpu.device.makeBuffer(length: row * frame.texture.height, options: .storageModeShared))
        let blit = try #require(frame.commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: frame.texture.width, height: frame.texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * frame.texture.height)
        blit.endEncoding()
        frame.commandBuffer.commit()
        // Readback is test-only. The production display loop never waits for completion.
        frame.commandBuffer.waitUntilCompleted()
        #expect(frame.commandBuffer.status == .completed)
        let values = buffer.contents().bindMemory(to: UInt16.self, capacity: buffer.length / 2)
        return (0..<(buffer.length / 2)).map { Float(Float16(bitPattern: values[$0])) }
    }

    private func distance(_ first: [Float], _ second: [Float]) -> Float {
        zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(first.count)
    }

    private func writePreview(_ values: [Float], name: String) throws {
        var bytes = values.enumerated().map { index, value in
            let encoded = index % 4 == 3 ? value : (value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055)
            return UInt8(min(255, max(0, (encoded * 255).rounded())))
        }
        try bytes.withUnsafeMutableBytes {
            let context = try #require(CGContext(data: $0.baseAddress, width: 192, height: 384,
                bitsPerComponent: 8, bytesPerRow: 192 * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            print("Artwork preview: \(url.path)")
        }
    }
}
