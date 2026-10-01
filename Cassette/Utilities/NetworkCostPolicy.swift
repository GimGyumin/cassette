// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Pure classification of how scarce the current connection is.
///
/// `NWPath.isExpensive` only reports metered links (cellular, hotspot). A Wi-Fi link the user
/// throttled, or one iOS reports as constrained (Low Data Mode), limits background caching,
/// prefetching and pre-buffering just as much — but it is *not* expensive. Every background
/// spend (ephemeral cache, gapless pre-buffer, crossfade prefetch, automatic download,
/// speculative artwork) funnels through this one rule so a limited Wi-Fi link is treated like
/// cellular instead of inheriting the unmetered path and starving the live stream.
nonisolated enum NetworkCostPolicy {
    /// Below this sustained rate (~2 Mbps) a link cannot reliably carry a lossless original or run
    /// background transfers alongside the live stream — whatever iOS reports about the path. This
    /// is what makes a throttled 1 Mbps Wi-Fi behave like cellular without Low Data Mode.
    static let slowBytesPerSecond: Double = 250_000

    /// True when background bandwidth should be treated as scarce: metered, constrained, **or**
    /// measured as slow.
    static func isLimited(
        isExpensive: Bool,
        isConstrained: Bool,
        measuredBytesPerSecond: Double? = nil
    ) -> Bool {
        if isExpensive || isConstrained { return true }
        return isSlow(measuredBytesPerSecond: measuredBytesPerSecond)
    }

    /// True when a measurement exists and is below the slow-link floor.
    static func isSlow(measuredBytesPerSecond: Double?) -> Bool {
        guard let measuredBytesPerSecond, measuredBytesPerSecond > 0 else { return false }
        return measuredBytesPerSecond < slowBytesPerSecond
    }
}
