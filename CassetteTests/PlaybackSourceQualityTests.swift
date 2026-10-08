import Testing
import Foundation
@testable import Cassette

@Suite(.serialized)
struct PlaybackSourceQualityTests {
    @Test func playableOriginalSkipsNegotiationOnlyForOriginalQuality() {
        for format in ["FLAC", "alac", "m4a", "wav"] {
            let song = DisplayableSong(id: "original", title: "Track", audioFormat: format,
                                      bitDepth: 24, samplingRate: 96_000, channelCount: 2)
            #expect(PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .flacOriginal, song: song))
            #expect(!PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .aac128, song: song))
        }
        for format in ["dsf", "ape", "unknown"] {
            let song = DisplayableSong(id: "unsupported", title: "Track", audioFormat: format)
            #expect(!PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .flacOriginal, song: song))
        }
        #expect(!PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .flacOriginal, song: nil))
    }

    @Test func losslessFallbackUsesOriginalInsteadOfJellyfinTranscoding() {
        let profile = iOSAudioCapability.deviceProfile(maxStreamingBitrate: nil, preferLossless: true)
        #expect(profile.TranscodingProfiles.isEmpty)
        let outcome = PlaybackDecisionPolicy.decide(.init(
            supportsDirectPlay: false, supportsDirectStream: false, supportsTranscoding: true,
            supportsHLSTranscoding: true, container: "flac", codec: "flac", preferLossless: true
        ))
        #expect(outcome.route == .openSubsonic)
        let direct = PlaybackDecisionPolicy.decide(.init(
            supportsDirectPlay: true, supportsTranscoding: true, supportsHLSTranscoding: true,
            container: "flac", codec: "flac", preferLossless: true
        ))
        #expect(direct.route == .directPlay)
    }

    @Test func automaticRequestsOriginalBytesOnFastWiFiAndCellular() {
        for limited in [true, false] {
            let format = AdaptiveQualityPolicy.effectiveFormat(configured: .matchStream,
                sourceBitRateKbps: 1_411, measuredBytesPerSecond: 1_000_000, isLimitedNetwork: limited)
            #expect(AdaptiveQualityPolicy.transportFormat(format).subsonicFormat == "raw")
        }
        #expect(AdaptiveQualityPolicy.transportFormat(.aac128) == .aac128)
    }

    @Test func explicitLosslessSurvivesEvenALegacyForcedCeiling() {
        #expect(AdaptiveQualityPolicy.effectiveFormat(configured: .flacOriginal,
            sourceBitRateKbps: 1_411, measuredBytesPerSecond: 20_000, ceiling: .aac128,
            applyCeilingToExplicitChoice: true) == .flacOriginal)
    }

    @Test @MainActor func recoveredConnectionIsNotPermanentlyCapped() {
        let settings = StreamingSettings()
        _ = settings.currentAdaptiveCeiling(isLimited: true)
        settings.adaptiveCeiling = .aac128
        #expect(settings.currentAdaptiveCeiling(isLimited: true) == .aac128)
        #expect(settings.currentAdaptiveCeiling(isLimited: false) == nil)
        settings.adaptiveCeiling = .aac128
        #expect(settings.currentAdaptiveCeiling(isLimited: false, now: Date().addingTimeInterval(121)) == nil)
    }

}
