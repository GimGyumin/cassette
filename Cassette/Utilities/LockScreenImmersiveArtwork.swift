// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import CoreGraphics
import AVFoundation
#if os(iOS)
import UIKit
import MediaPlayer

/// System-facing 3:4 artwork. Preserve the original sleeve and extend its edges;
/// a still video provides a clean loop without inventing motion in printed artwork.
@available(iOS 26.0, *)
enum LockScreenImmersiveArtwork {
    nonisolated static func make(_ image: UIImage) async -> MPMediaItemAnimatedArtwork? {
        let prepared = await Task.detached(priority: .utility) { () -> (UIImage, UInt64)? in
            guard let cg = image.cgImage, let facts = ArtworkEdgeAnalyzer.analyze(cg),
                  facts.presentationStyle != .standard, facts.isOpaque else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            func color(_ packed: Int) -> UIColor {
                UIColor(red: CGFloat((packed >> 16) & 255) / 255,
                        green: CGFloat((packed >> 8) & 255) / 255,
                        blue: CGFloat(packed & 255) / 255, alpha: 1)
            }
            let top = color(facts.packedTopBackground ?? facts.packedBackground)
            let bottom = color(facts.packedBottomBackground ?? facts.packedBackground)
            let preview = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
                top.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                bottom.setFill()
                renderer.fill(CGRect(x: 0, y: 600, width: 600, height: 200))
                image.draw(in: CGRect(x: 0, y: 64, width: 600, height: 600))
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [bottom.withAlphaComponent(0).cgColor, bottom.cgColor] as CFArray,
                    locations: [0, 1]) {
                    renderer.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 610),
                        end: CGPoint(x: 0, y: 664), options: [])
                }
            }
            return (preview, facts.fingerprint)
        }.value
        guard let (preview, fingerprint) = prepared else { return nil }
        guard let frame = preview.cgImage else { return nil }
        let asset = StillArtworkVideo(image: frame)
        return MPMediaItemAnimatedArtwork(
            artworkID: "cassette-tall-v1-\(fingerprint)",
            previewImageRequestHandler: { _ in preview },
            videoAssetFileURLRequestHandler: { _ in await asset.fileURL() }
        )
    }
}

#endif

actor StillArtworkVideo {
    let image: CGImage
    private var task: Task<URL?, Never>?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-art-\(UUID()).mp4")
    init(image: CGImage) { self.image = image }
    deinit { try? FileManager.default.removeItem(at: url) }

    func fileURL() async -> URL? {
        if let task { return await task.value }
        let task = Task.detached(priority: .utility) { [image, url] in
            await Self.write(image: image, url: url)
        }
        self.task = task
        return await task.value
    }

    nonisolated private static func write(image: CGImage, url: URL) async -> URL? {
        let cg = image
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 600, AVVideoHeightKey: 800
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: 600, kCVPixelBufferHeightKey as String: 800,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)
            guard let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); return nil }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { writer.cancelWriting(); return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 600, height: 800,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, []); writer.cancelWriting(); return nil
            }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 600, height: 800))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = ContinuousClock.now + .seconds(5)
            for second in 0..<2 {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, ContinuousClock.now < deadline, !Task.isCancelled else {
                        writer.cancelWriting(); return nil
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else {
                    writer.cancelWriting(); return nil
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
            await writer.finishWriting()
            return writer.status == .completed ? url : nil
        } catch { return nil }
    }
}
