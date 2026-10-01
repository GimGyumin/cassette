// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

// MARK: - Pure policy

@Suite("AdaptiveQualityPolicy.effectiveFormat")
struct AdaptiveQualityFormatTests {

    @Test func explicitQualityIsNeverOverridden() {
        // A chosen quality is an instruction, even on a slow link.
        for configured in [CacheFormat.flacOriginal, .aac256, .aac128, .opus_128] {
            #expect(
                AdaptiveQualityPolicy.effectiveFormat(
                    configured: configured,
                    sourceBitRateKbps: 1_411,
                    measuredBytesPerSecond: 20_000
                ) == configured
            )
        }
    }

    @Test func noMeasurementKeepsAutomatic() {
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 1_411,
                measuredBytesPerSecond: nil
            ) == .matchStream
        )
    }

    @Test func slowCellularLowersAutomaticQuality() {
        // ~1 Mbps measured → 400 kbps usable; a lossless original does not fit.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 1_411,
                measuredBytesPerSecond: 125_000
            ) == .aac256
        )
    }

    @Test func verySlowLinkDropsToTheSmallestTier() {
        // ~300 kbps measured → 120 kbps usable, below AAC 256.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 1_411,
                measuredBytesPerSecond: 37_500
            ) == .aac128
        )
    }

    @Test func sourceThatFitsKeepsAutomatic() {
        // ~5 Mbps measured → 2 Mbps usable, comfortably above a 128 kbps source.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 128,
                measuredBytesPerSecond: 625_000
            ) == .matchStream
        )
    }

    @Test func unknownSourceFallsBackToConservativeCeiling() {
        // No source bitrate: assume a server default (1.8 Mbps) rather than a lossless original.
        // ~4 Mbps measured → 2 Mbps usable, which can carry the assumed default.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: nil,
                measuredBytesPerSecond: 500_000
            ) == .matchStream
        )
        // ~512 kbps measured → 256 kbps usable, just enough for AAC 256 but not the assumed default.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: nil,
                measuredBytesPerSecond: 64_000
            ) == .aac256
        )
    }

    @Test func usableThroughputKeepsHeadroom() {
        #expect(AdaptiveQualityPolicy.usableKbps(measuredBytesPerSecond: 125_000) == 500)
        #expect(AdaptiveQualityPolicy.usableKbps(measuredBytesPerSecond: nil) == nil)
        #expect(AdaptiveQualityPolicy.usableKbps(measuredBytesPerSecond: 0) == nil)
    }

    @Test func sessionCeilingLowersAutomaticAndNeverRaisesIt() {
        // A fast measurement would keep Automatic, but the ceiling learned from an underrun wins.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 128,
                measuredBytesPerSecond: 625_000,
                ceiling: .aac128
            ) == .aac128
        )
        // A ceiling above the adapted result must not raise quality.
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .matchStream,
                sourceBitRateKbps: 1_411,
                measuredBytesPerSecond: 37_500,
                ceiling: .aac256
            ) == .aac128
        )
    }

    @Test func ceilingNeverTouchesAnExplicitChoice() {
        #expect(
            AdaptiveQualityPolicy.effectiveFormat(
                configured: .flacOriginal,
                sourceBitRateKbps: 1_411,
                measuredBytesPerSecond: 37_500,
                ceiling: .aac128
            ) == .flacOriginal
        )
    }

    @Test func lowerTierStepsDownToTheFloor() {
        #expect(AdaptiveQualityPolicy.lowerTier(.matchStream) == .aac256)
        #expect(AdaptiveQualityPolicy.lowerTier(.flacOriginal) == .aac256)
        #expect(AdaptiveQualityPolicy.lowerTier(.aac256) == .aac128)
        #expect(AdaptiveQualityPolicy.lowerTier(.aac128) == nil)
    }

    @Test func qualityRankOrdersDataPerSecond() {
        #expect(AdaptiveQualityPolicy.qualityRank(.matchStream) > AdaptiveQualityPolicy.qualityRank(.aac256))
        #expect(AdaptiveQualityPolicy.qualityRank(.aac256) > AdaptiveQualityPolicy.qualityRank(.aac128))
    }
}

@Suite("AdaptiveQualityPolicy.streamingCeilingKbps")
struct AdaptiveQualityCeilingTests {

    @Test func automaticUsesTheMeasuredLink() {
        // ~1 Mbps → 500 kbps usable, which is what travels to the server as MaxStreamingBitrate.
        #expect(
            AdaptiveQualityPolicy.streamingCeilingKbps(
                configured: .matchStream,
                measuredBytesPerSecond: 125_000
            ) == 500
        )
    }

    @Test func explicitQualityIsCappedByTheLink() {
        // The user asked for 256 kbps but the link only carries ~120 kbps usable.
        #expect(
            AdaptiveQualityPolicy.streamingCeilingKbps(
                configured: .aac256,
                measuredBytesPerSecond: 30_000
            ) == 120
        )
        // …and an explicit choice is used as-is when the link is faster.
        #expect(
            AdaptiveQualityPolicy.streamingCeilingKbps(
                configured: .aac128,
                measuredBytesPerSecond: 1_250_000
            ) == 128
        )
    }

    @Test func explicitLosslessIsUncappedByDefault() {
        // "Lossless" is an instruction for the original; only an underrun-learned ceiling may lower it.
        #expect(
            AdaptiveQualityPolicy.streamingCeilingKbps(
                configured: .flacOriginal,
                measuredBytesPerSecond: 125_000
            ) == nil
        )
    }

    @Test func noMeasurementAndNoChoiceMeansNoCeiling() {
        #expect(
            AdaptiveQualityPolicy.streamingCeilingKbps(
                configured: .matchStream,
                measuredBytesPerSecond: nil
            ) == nil
        )
    }
}

// MARK: - Probe

private actor FakeSpeedSampler: SpeedSampling {
    private let rate: Double?
    private(set) var callCount = 0

    init(rate: Double?) {
        self.rate = rate
    }

    func sample(url: URL, headers: [String: String], maxBytes: Int, budget: TimeInterval) async -> Double? {
        callCount += 1
        return rate
    }
}

@Suite("NetworkSpeedProbe")
struct NetworkSpeedProbeTests {

    private let url = URL(string: "https://music.example/rest/stream?id=1")!

    @Test func reusesOneMeasurementPerServer() async {
        let sampler = FakeSpeedSampler(rate: 250_000)
        let probe = NetworkSpeedProbe(sampler: sampler, ttl: 300, maxBytes: 1_024, budget: 1)

        // Two different servers each pay for their own probe.
        _ = await probe.measurement(serverId: UUID(), url: url, headers: [:])
        _ = await probe.measurement(serverId: UUID(), url: url, headers: [:])
        #expect(await sampler.callCount == 2)

        // The same server reuses the cached rate.
        let serverId = UUID()
        _ = await probe.measurement(serverId: serverId, url: url, headers: [:])
        let second = await probe.measurement(serverId: serverId, url: url, headers: [:])
        #expect(second == 250_000)
        #expect(await sampler.callCount == 3)
    }

    @Test func failedSampleIsNotCached() async {
        let sampler = FakeSpeedSampler(rate: nil)
        let probe = NetworkSpeedProbe(sampler: sampler, ttl: 300, maxBytes: 1_024, budget: 1)
        let serverId = UUID()

        #expect(await probe.measurement(serverId: serverId, url: url, headers: [:]) == nil)
        #expect(await probe.measurement(serverId: serverId, url: url, headers: [:]) == nil)
        #expect(await sampler.callCount == 2, "a nil measurement must be retried, not cached")
    }

    @Test func expiredMeasurementIsResampled() async {
        let sampler = FakeSpeedSampler(rate: 100_000)
        let probe = NetworkSpeedProbe(sampler: sampler, ttl: 0, maxBytes: 1_024, budget: 1)
        let serverId = UUID()

        _ = await probe.measurement(serverId: serverId, url: url, headers: [:])
        _ = await probe.measurement(serverId: serverId, url: url, headers: [:])
        #expect(await sampler.callCount == 2, "a zero TTL must not serve a stale rate")
    }
}
