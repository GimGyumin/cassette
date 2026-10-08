// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Pure policy that turns a measured connection speed into a stream-quality ceiling.
///
/// Only the "Automatic" quality (`CacheFormat.matchStream`) and the "Automatic" server playback
/// method adapt: an explicit choice (Lossless, AAC 256, Direct Play, …) is the user's instruction
/// and is always honored. The ceiling keeps headroom over the codec bitrate so a fluctuation, a
/// TLS retry or a competing background request cannot starve the live stream.
nonisolated enum AdaptiveQualityPolicy {
    /// Automatic that can carry the source must request original bytes explicitly. A missing
    /// Subsonic format lets the server's own AAC default silently override the client's decision.
    static func transportFormat(_ effectiveFormat: CacheFormat) -> CacheFormat {
        effectiveFormat == .matchStream ? .flacOriginal : effectiveFormat
    }

    /// Fraction of the measured rate a stream may use. Half leaves room for retries, protocol
    /// overhead and the occasional artwork request.
    static let usableFraction = 0.5

    /// What "Automatic" is assumed to need when the source bitrate is not reported yet. Server
    /// defaults are frequently a lossless original, so this is deliberately conservative.
    static let assumedAutomaticKbps: Double = 1_800

    /// Highest explicit format that fits `usableKbps`.
    static func fittingFormat(usableKbps: Double) -> CacheFormat {
        let aac256 = Double(CacheFormat.aac256.subsonicMaxBitRate ?? 256)
        return usableKbps >= aac256 ? .aac256 : .aac128
    }

    /// Headroom used on an **unmetered, unconstrained** link (Wi-Fi). Losing a fifth to TLS retries,
    /// protocol overhead and artwork is enough there, and Automatic then keeps the original whenever
    /// the file itself fits the measurement. Applying the metered half-rate rule on Wi-Fi is what
    /// turned a ~1.7 Mbps measurement into a 397 kbps transcode for a lossless album.
    static let unmeteredUsableFraction = 0.8

    /// Usable throughput (kbps) after the headroom fraction. `nil` when nothing was measured.
    static func usableKbps(
        measuredBytesPerSecond: Double?,
        isLimitedNetwork: Bool = true
    ) -> Double? {
        guard let measuredBytesPerSecond, measuredBytesPerSecond > 0 else { return nil }
        let fraction = isLimitedNetwork ? usableFraction : unmeteredUsableFraction
        return measuredBytesPerSecond * 8 / 1_000 * fraction
    }

    /// The bitrate ceiling a resolve should be capped to, in kbps, combining the user's quality
    /// choice with the measured link — whichever is stricter. `nil` means "no known ceiling", which
    /// is also what an explicit Lossless choice yields: the user asked for the original.
    ///
    /// This is what travels to the server as `MaxStreamingBitrate`, so a Jellyfin implementation that
    /// honours it answers Direct Play vs Transcoding for *this* connection instead of for a
    /// hypothetical fast one.
    static func streamingCeilingKbps(
        configured: CacheFormat,
        sourceBitRateKbps: Int? = nil,
        measuredBytesPerSecond: Double?,
        isLimitedNetwork: Bool = true
    ) -> Double? {
        let configuredKbps = configured.subsonicMaxBitRate.map(Double.init)
        let measuredKbps = usableKbps(
            measuredBytesPerSecond: measuredBytesPerSecond,
            isLimitedNetwork: isLimitedNetwork
        )
        switch (configuredKbps, measuredKbps) {
        case let (configured?, measured?): return min(configured, measured)
        case let (configured?, nil): return configured
        case let (nil, measured?):
            guard configured == .matchStream else { return nil }
            // Automatic: the ceiling only exists to keep a stream the link cannot carry off the wire.
            // When the file itself fits the measurement, report *no* ceiling so the server answers
            // Direct Play instead of transcoding to a bitrate that merely sits under the measurement.
            let required = sourceBitRateKbps.map(Double.init) ?? assumedAutomaticKbps
            return required <= measured ? nil : measured
        case (nil, nil): return nil
        }
    }

    /// Effective stream format for a resolve.
    ///
    /// Only lowers quality, never raises it: `.matchStream` is returned whenever the connection
    /// can afford the file the server would serve anyway.
    static func effectiveFormat(
        configured: CacheFormat,
        sourceBitRateKbps: Int?,
        measuredBytesPerSecond: Double?,
        isLimitedNetwork: Bool = true
    ) -> CacheFormat {
        guard configured == .matchStream else { return configured }
        guard let usable = usableKbps(
            measuredBytesPerSecond: measuredBytesPerSecond,
            isLimitedNetwork: isLimitedNetwork
        ) else {
            return configured
        }
        let required = sourceBitRateKbps.map(Double.init) ?? assumedAutomaticKbps
        guard required > usable else { return configured }
        return fittingFormat(usableKbps: usable)
    }

    /// Comparison used only to keep a ceiling from *raising* quality.
    /// Higher means more data per second, so a lower rank is the safer choice.
    static func qualityRank(_ format: CacheFormat) -> Int {
        switch format {
        case .matchStream, .flacOriginal: return 4
        case .aac256, .mp3_320: return 3
        case .opus_128, .mp3_192: return 2
        case .aac128: return 1
        }
    }

    /// Next step down when a link has proven too slow for the current Automatic choice.
    static func lowerTier(_ format: CacheFormat) -> CacheFormat? {
        switch format {
        case .matchStream, .flacOriginal: return .aac256
        case .aac256, .mp3_320: return .aac128
        default: return nil
        }
    }

    /// `effectiveFormat` with the session's adaptive ceiling applied.
    ///
    /// The ceiling is what an underrun on this link taught us, so it wins over a fresh (and
    /// possibly optimistic) measurement — but only for Automatic. An explicit user choice is still
    /// never overridden.
    static func effectiveFormat(
        configured: CacheFormat,
        sourceBitRateKbps: Int?,
        measuredBytesPerSecond: Double?,
        ceiling: CacheFormat?,
        isLimitedNetwork: Bool = true,
        applyCeilingToExplicitChoice: Bool = false
    ) -> CacheFormat {
        let adapted = effectiveFormat(
            configured: configured,
            sourceBitRateKbps: sourceBitRateKbps,
            measuredBytesPerSecond: measuredBytesPerSecond,
            isLimitedNetwork: isLimitedNetwork
        )
        guard let ceiling else { return adapted }
        // Explicit quality remains authoritative, including callers carrying the legacy override.
        guard configured == .matchStream else { return adapted }
        return qualityRank(adapted) <= qualityRank(ceiling) ? adapted : ceiling
    }
}
