import Foundation
import CoreGraphics
import Metal
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Statistics describe the artwork, never an album-specific replacement palette.
/// Both uniforms and render targets use linear Display P3 primaries.
nonisolated struct ArtworkSceneColorProfile: Sendable {
    var average: SIMD4<Float>
    var distribution: SIMD4<Float>
    var colorAnchor: SIMD4<Float> = .zero
    static let neutral = Self(average: SIMD4(0.12, 0.12, 0.12, 0.12),
                              distribution: SIMD4(0.02, 0.6, 0.35, 0))

    static func decode(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func analyze(rgba: [UInt8], width: Int, height: Int) -> Self {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            return .init(average: .zero, distribution: .zero)
        }
        var sum = SIMD3<Float>.zero
        var weight: Float = 0
        var saturation: Float = 0
        var chromaticSum = SIMD3<Float>.zero
        var chromaticWeight: Float = 0
        var luminances: [Float] = []
        // At most 32 × 32 samples, once per prepared image, off the main actor.
        for y in stride(from: 0, to: height, by: max(1, (height + 31) / 32)) {
            for x in stride(from: 0, to: width, by: max(1, (width + 31) / 32)) {
                let i = (y * width + x) * 4
                let alpha = Float(rgba[i + 3]) / 255
                guard alpha > 0 else { continue }
                let encoded = SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255
                let linear = SIMD3(decode(encoded.x), decode(encoded.y), decode(encoded.z))
                let luma = linear.x * 0.2289746 + linear.y * 0.6917385 + linear.z * 0.0792869
                sum += linear * alpha
                weight += alpha
                let high = max(encoded.x, max(encoded.y, encoded.z))
                let low = min(encoded.x, min(encoded.y, encoded.z))
                let chroma = high > 0 ? (high - low) / high : 0
                saturation += chroma * alpha
                // Preserve the cover's colored field instead of letting neutral faces/black
                // lettering wash it out. Every hue uses the same continuous weight.
                let colorWeight = (0.25 + chroma * 1.5) * alpha
                chromaticSum += linear * colorWeight
                chromaticWeight += colorWeight
                luminances.append(luma)
            }
        }
        guard weight > 0 else { return .init(average: .zero, distribution: .zero) }
        let mean = sum / weight
        luminances.sort()
        let meanLuma = mean.x * 0.2289746 + mean.y * 0.6917385 + mean.z * 0.0792869
        let anchor = chromaticSum / chromaticWeight
        return .init(average: SIMD4(mean.x, mean.y, mean.z, meanLuma),
                     distribution: SIMD4(luminances[(luminances.count - 1) / 10],
                         luminances[(luminances.count - 1) * 9 / 10], saturation / weight, 0),
                     colorAnchor: SIMD4(anchor.x, anchor.y, anchor.z, 1))
    }
}

/// A weak source identity avoids retaining full-size hero images beyond the existing image cache.
nonisolated final class PreparedArtworkScene: @unchecked Sendable {
    private(set) weak var image: PlatformImage?
    let texture: any MTLTexture
    let profile: ArtworkSceneColorProfile

    init(image: PlatformImage, texture: any MTLTexture, profile: ArtworkSceneColorProfile) {
        self.image = image
        self.texture = texture
        self.profile = profile
    }

    static func prepare(image: PlatformImage, device: any MTLDevice) -> PreparedArtworkScene? {
        guard !Task.isCancelled else { return nil }
        #if os(iOS)
        guard let original = image.cgImage else { return nil }
        #else
        guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let dimension = max(1, min(512, min(original.width, original.height)))
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        let scale = CGFloat(dimension) / CGFloat(min(original.width, original.height))
        let width = CGFloat(original.width) * scale, height = CGFloat(original.height) * scale
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: (CGFloat(dimension) - width) / 2,
            y: (CGFloat(dimension) - height) / 2, width: width, height: height))
        guard !Task.isCancelled, let data = context.data else { return nil }
        var bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                             count: dimension * dimension * 4))
        // Gamma-encoded premultiplied channels must be unassociated before hardware decoding.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[i + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 { bytes[i + channel] = UInt8(min(255, Int(bytes[i + channel]) * 255 / alpha)) }
            }
        }
        let profile = ArtworkSceneColorProfile.analyze(rgba: bytes, width: dimension, height: dimension)
        guard !Task.isCancelled else { return nil }
        // Display P3 uses the sRGB transfer function; this flag decodes that function, not primaries.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: dimension, height: dimension, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, dimension, dimension), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: dimension * 4)
        }
        return .init(image: image, texture: texture, profile: profile)
    }
}

/// Reuses the existing ArtworkImageCache's image objects. No disk/network cache is duplicated.
/// Simultaneous player/sidebar requests share preparation; cancellation stops an unneeded worker.
actor ArtworkSceneTextureCache {
    static let shared = ArtworkSceneTextureCache()
    private struct Key: Hashable { let image: ObjectIdentifier; let device: UInt64 }
    private struct Job {
        let id: UUID
        let task: Task<PreparedArtworkScene?, Never>
        var subscribers: Set<UUID>
    }
    private var ready: [Key: PreparedArtworkScene] = [:]
    private var recent: [Key] = []
    private var jobs: [Key: Job] = [:]

    func artwork(image: PlatformImage, device: any MTLDevice) async -> PreparedArtworkScene? {
        guard !Task.isCancelled else { return nil }
        let key = Key(image: ObjectIdentifier(image), device: device.registryID)
        if let cached = ready[key], cached.image === image { touch(key); return cached }
        // A deallocated source may have its address reused by an unrelated UIImage/NSImage.
        ready[key] = nil
        let subscriber = UUID()
        if jobs[key] == nil {
            jobs[key] = Job(id: UUID(), task: Task.detached(priority: .utility) {
                PreparedArtworkScene.prepare(image: image, device: device)
            }, subscribers: [])
        }
        jobs[key]?.subscribers.insert(subscriber)
        guard let job = jobs[key] else { return nil }
        let result = await withTaskCancellationHandler { await job.task.value } onCancel: {
            Task { await self.cancel(key: key, subscriber: subscriber, jobID: job.id) }
        }
        guard !Task.isCancelled else { cancel(key: key, subscriber: subscriber, jobID: job.id); return nil }
        if jobs[key]?.id == job.id {
            jobs[key] = nil
            if let result {
                ready[key] = result
                touch(key)
                while recent.count > 6 { ready[recent.removeFirst()] = nil }
            }
        }
        return result
    }

    func removeCachedArtwork() { ready.removeAll(); recent.removeAll() }

    private func touch(_ key: Key) { recent.removeAll { $0 == key }; recent.append(key) }
    private func cancel(key: Key, subscriber: UUID, jobID: UUID) {
        guard jobs[key]?.id == jobID else { return }
        jobs[key]?.subscribers.remove(subscriber)
        if jobs[key]?.subscribers.isEmpty == true { jobs[key]?.task.cancel(); jobs[key] = nil }
    }
}
