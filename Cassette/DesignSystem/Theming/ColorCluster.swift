// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// One K-means cluster in CIELAB space used by `AlbumColorAnalyzer`.
struct ColorCluster: Equatable, Sendable {
    /// Cluster centroid in CIELAB.
    var L: Double
    var a: Double
    var b: Double
    /// Mean sRGB of members (0…1).
    var r: Double
    var g: Double
    var bChannel: Double
    /// Pixel membership count.
    var count: Int
    /// Mean edge weight (higher near frame / backdrop).
    var edgeWeight: Double

    var chroma: Double { hypot(a, b) }

    var sizeFraction: Double {
        // Caller supplies total when scoring; stored as absolute count only.
        Double(count)
    }
}
