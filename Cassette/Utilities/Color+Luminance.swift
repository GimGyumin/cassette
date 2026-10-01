// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// Perceived luminance using ITU-R BT.601 coefficients.
    /// Values > 0.6 indicate a light background that needs dark content.
    ///
    /// Uses UIKit/AppKit bridges — SwiftUI `cgColor?.components` is unreliable for asset /
    /// Display-P3 colours and previously mis-classified dark covers as light (black text on black).
    var luminance: Double {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        #elseif canImport(AppKit)
        guard let ns = NSColor(self).usingColorSpace(.deviceRGB) else { return 0 }
        return 0.299 * Double(ns.redComponent)
            + 0.587 * Double(ns.greenComponent)
            + 0.114 * Double(ns.blueComponent)
        #else
        return 0
        #endif
    }
}
