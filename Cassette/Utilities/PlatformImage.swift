// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

import SwiftUI

extension PlatformImage {
    /// Compressed JPEG size is not representative of the retained pixel buffer.
    nonisolated var decodedMemoryCost: Int {
        #if canImport(UIKit)
        if let cgImage { return cgImage.bytesPerRow * cgImage.height }
        return Int(ceil(size.width * scale)) * Int(ceil(size.height * scale)) * 4
        #else
        if let bitmap = representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return bitmap.bytesPerRow * bitmap.pixelsHigh
        }
        return Int(ceil(size.width)) * Int(ceil(size.height)) * 4
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
