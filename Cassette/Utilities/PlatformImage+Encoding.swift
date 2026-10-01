// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension PlatformImage {
    /// Returns a copy scaled down so neither dimension exceeds maxDimension.
    /// Returns self unchanged if already within bounds.
    nonisolated func resized(maxDimension: CGFloat) -> PlatformImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        let scale = maxDimension / maxSide
        let newSize = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        #if canImport(UIKit)
        // Opaque format avoids AlphaPremulLast on cover art that has no transparency.
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: newSize))
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        #elseif canImport(AppKit)
        let result = NSImage(size: newSize)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
        #endif
    }

    /// JPEG-encodes the receiver at the given quality (0.0–1.0).
    nonisolated func jpgData(quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        // Flatten through an opaque bitmap so ImageIO never writes AlphaPremulLast for covers.
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let opaque = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            draw(in: CGRect(origin: .zero, size: size))
        }
        return opaque.jpegData(compressionQuality: quality)
        #elseif canImport(AppKit)
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }
}
