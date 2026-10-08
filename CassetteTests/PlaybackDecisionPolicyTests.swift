// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

// MARK: - Device capability

@Suite("iOSAudioCapability")
struct iOSAudioCapabilityTests {

    @Test func losslessAndLossyFormatsPlayDirectly() {
        #expect(iOSAudioCapability.canDecodeDirectly(container: "alac", codec: "alac", sampleRate: 44_100, bitDepth: 16))
        #expect(iOSAudioCapability.canDecodeDirectly(container: "flac", codec: nil, sampleRate: 96_000, bitDepth: 24))
        #expect(iOSAudioCapability.canDecodeDirectly(container: "m4a", codec: "aac", sampleRate: nil, bitDepth: nil))
        #expect(iOSAudioCapability.canDecodeDirectly(container: "mp3", codec: "mp3", sampleRate: nil, bitDepth: nil))
        #expect(iOSAudioCapability.canDecodeDirectly(container: "ogg", codec: "vorbis", sampleRate: nil, bitDepth: nil))
    }

    @Test func normalizesDottedAndCommaSeparatedContainers() {
        // Servers write ".flac", "audio/flac" or "m4a,aac" depending on the implementation.
        #expect(iOSAudioCapability.canDecodeDirectly(container: ".FLAC", codec: nil, sampleRate: nil, bitDepth: nil))
        #expect(iOSAudioCapability.canDecodeDirectly(container: "m4a,aac", codec: nil, sampleRate: nil, bitDepth: nil))
        #expect(iOSAudioCapability.canDecodeDirectly(container: nil, codec: "AAC", sampleRate: nil, bitDepth: nil))
    }

    @Test func exoticFormatsAreNeverHandedToTheEngine() {
        // DSD / WavPack / unknown containers must be transcoded, not guessed at.
        #expect(!iOSAudioCapability.canDecodeDirectly(container: "dsf", codec: "dsd", sampleRate: nil, bitDepth: nil))
        #expect(!iOSAudioCapability.canDecodeDirectly(container: "wv", codec: nil, sampleRate: nil, bitDepth: nil))
        #expect(!iOSAudioCapability.canDecodeDirectly(container: "bin", codec: nil, sampleRate: nil, bitDepth: nil))
    }

    @Test func silenceIsNotALicenceToGuess() {
        // No container and no codec means the server told us nothing usable.
        #expect(!iOSAudioCapability.canDecodeDirectly(container: nil, codec: nil, sampleRate: nil, bitDepth: nil))
    }

    @Test func knownMimeTypeCanStartOriginalWithoutPlaybackInfo() {
        let flac = DisplayableSong(id: "flac", title: "FLAC", contentType: "audio/flac; charset=binary")
        #expect(PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .flacOriginal, song: flac))
        #expect(!PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .aac256, song: flac))
        let unknown = DisplayableSong(id: "unknown", title: "Unknown", contentType: "audio/x-unknown")
        #expect(!PlaybackDecisionPolicy.canStreamOriginalImmediately(format: .flacOriginal, song: unknown))
    }

    @Test func exceedsEngineLimits() {
        #expect(!iOSAudioCapability.canDecodeDirectly(container: "flac", codec: "flac", sampleRate: 384_000, bitDepth: 24))
        #expect(!iOSAudioCapability.canDecodeDirectly(container: "flac", codec: "flac", sampleRate: 48_000, bitDepth: 32))
    }

    @Test func deviceProfileAdvertisesContainersAndTranscoders() {
        let profile = iOSAudioCapability.deviceProfile(maxStreamingBitrate: 256_000)
        #expect(profile.Name == "Cassette")
        #expect(profile.MaxStreamingBitrate == 256_000)
        #expect(profile.DirectPlayProfiles.contains { $0.Container == "alac" && $0.AudioCodec == "alac" })
        #expect(profile.TranscodingProfiles.contains { $0.Container == "aac" })
    }
}

// MARK: - Audio stream selection

@Suite("JellyfinMediaSource.defaultAudioStream")
struct JellyfinDefaultAudioStreamTests {

    private func source(_ streams: [JellyfinMediaStream]?) -> JellyfinMediaSource {
        JellyfinMediaSource(
            id: "ms", name: nil, path: nil, container: "m4a",
            supportsDirectPlay: true, supportsDirectStream: true, supportsTranscoding: true,
            transcodingURL: nil, transcodingContainer: nil, transcodingSubProtocol: nil,
            mediaStreams: streams, bitrate: nil, containerSize: nil
        )
    }

    @Test func prefersTheDefaultAudioStream() {
        let stream = source([
            JellyfinMediaStream(type: "Video", codec: "h264", channels: nil, sampleRate: nil, bitDepth: nil, bitRate: nil, isDefault: false),
            JellyfinMediaStream(type: "Audio", codec: "aac", channels: 2, sampleRate: 44_100, bitDepth: nil, bitRate: nil, isDefault: false),
            JellyfinMediaStream(type: "Audio", codec: "alac", channels: 2, sampleRate: 48_000, bitDepth: 16, bitRate: nil, isDefault: true),
        ]).defaultAudioStream
        #expect(stream?.codec == "alac")
    }

    @Test func fallsBackToTheFirstAudioStream() {
        let stream = source([
            JellyfinMediaStream(type: "Audio", codec: "mp3", channels: 2, sampleRate: nil, bitDepth: nil, bitRate: nil, isDefault: nil),
        ]).defaultAudioStream
        #expect(stream?.codec == "mp3")
    }

    @Test func nilWhenNoStreamDetailWasReturned() {
        #expect(source(nil).defaultAudioStream == nil)
    }
}

// MARK: - Route decision

@Suite("PlaybackDecisionPolicy")
struct PlaybackDecisionPolicyTests {
    @Test func advertisedHLSTranscodeIsPreferredOnASlowLink() {
        var inputs = capableSource
        inputs.container = "flac"
        inputs.sourceBitRate = 2_000_000
        inputs.ceilingBitsPerSecond = 256_000
        inputs.supportsHLSTranscoding = true
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .hls)
        inputs.supportsHLSTranscoding = false
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .universal)
        inputs.supportsTranscoding = false
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .openSubsonic)
    }

    @Test func selectedLossyFormatNeverUsesRawDirectPlayWhenMetadataIsMissing() {
        var inputs = capableSource
        inputs.requiresLossyEncoding = true
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .universal)
        inputs.supportsHLSTranscoding = true
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .hls)
        inputs.supportsTranscoding = false
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .openSubsonic)
    }

    @Test func hlsDoesNotTranscodeAnOriginalThatFits() {
        var inputs = capableSource
        inputs.container = "flac"
        inputs.sourceBitRate = 900_000
        inputs.ceilingBitsPerSecond = 1_500_000
        inputs.supportsHLSTranscoding = true
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .directPlay)
    }

    @Test func serverCanRequireTranscodingEvenForADecodableFile() {
        var inputs = capableSource
        inputs.container = "mp3"
        inputs.supportsDirectPlay = false
        inputs.supportsDirectStream = false
        inputs.supportsHLSTranscoding = true
        #expect(PlaybackDecisionPolicy.decide(inputs).route == .hls)
    }

    /// A server that can do everything, so the ceiling and codec decide the outcome.
    private var capableSource: PlaybackDecisionPolicy.Inputs {
        PlaybackDecisionPolicy.Inputs(
            requestedRoute: .automatic,
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
    }

    @Test func lanWithLosslessStaysDirectPlay() {
        // Home Wi-Fi, no ceiling: the ALAC original plays untouched.
        var inputs = capableSource
        inputs.container = "alac"
        inputs.codec = "alac"
        inputs.sourceBitRate = 900_000
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .directPlay)
        #expect(outcome.reason == .directPlayFits)
    }

    @Test func slowLinkTranscodesLosslessInsteadOfDirectPlay() {
        // The exact case the brief calls out: ALAC 900 kbps under a 256 kbps cellular cap.
        var inputs = capableSource
        inputs.container = "alac"
        inputs.codec = "alac"
        inputs.sourceBitRate = 900_000
        inputs.ceilingBitsPerSecond = 256_000
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .universal)
        #expect(outcome.reason == .directPlayOverCeiling)
    }

    @Test func unreportedBitrateJudgesLosslessByContainer() {
        // Navidrome may omit Bitrate: a lossless container must not be assumed to fit.
        var inputs = capableSource
        inputs.container = "flac"
        inputs.sourceBitRate = nil
        inputs.ceilingBitsPerSecond = 256_000
        #expect(PlaybackDecisionPolicy.decide(inputs).reason == .directPlayOverCeiling)

        // …while a lossy container is assumed to fit, so a fast 5G link keeps Direct Play.
        var lossy = capableSource
        lossy.container = "mp3"
        lossy.sourceBitRate = nil
        lossy.ceilingBitsPerSecond = 256_000
        #expect(PlaybackDecisionPolicy.decide(lossy).route == .directPlay)
    }

    @Test func configuredLowQualityCapsLosslessEvenWithoutAMeasurement() {
        // Settings → Audio Quality is a ceiling of its own: the cellular default (AAC 128) caps an
        // ALAC original before anything measured the link, so the resolve asks for a transcode.
        var inputs = capableSource
        inputs.container = "alac"
        inputs.codec = "alac"
        inputs.sourceBitRate = 900_000
        inputs.ceilingBitsPerSecond = 128_000
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .universal)
        #expect(outcome.reason == .directPlayOverCeiling)
    }

    @Test func jellyfinTransportNeedsTheFeatureAndAMappedID() {
        // Which endpoint resolves the audio is a capability question, not a stored route: the
        // playback-method menu is gone, so nothing else may send a song to PlaybackInfo.
        #expect(PlaybackDecisionPolicy.usesJellyfinTransport(hasJellyfinService: true, jellyfinItemID: "0a1b2c"))
        #expect(!PlaybackDecisionPolicy.usesJellyfinTransport(hasJellyfinService: true, jellyfinItemID: nil))
        #expect(!PlaybackDecisionPolicy.usesJellyfinTransport(hasJellyfinService: false, jellyfinItemID: "0a1b2c"))
    }

    @Test func codecTheEngineCannotDecodeIsTranscoded() {
        var inputs = capableSource
        inputs.container = "dsf"
        inputs.codec = "dsd"
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .universal)
        #expect(outcome.reason == .directPlayUnsupportedCodec)
    }

    @Test func dolbyBitstreamIsNeverTranscoded() {
        var inputs = capableSource
        inputs.requiresBitstream = true
        inputs.ceilingBitsPerSecond = 128_000
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .directPlay)
        #expect(outcome.reason == .bitstream)
    }

    @Test func downloadedFileIsAlwaysDirectPlay() {
        var inputs = capableSource
        inputs.sourceIsLocal = true
        inputs.container = "dsf"
        #expect(PlaybackDecisionPolicy.decide(inputs).reason == .localFile)
    }

    @Test func explicitRouteIsNeverOverridden() {
        for route in [JellyfinPlaybackRoute.directPlay, .universal, .hls, .originalFile, .openSubsonic] {
            var inputs = capableSource
            inputs.requestedRoute = route
            inputs.container = "dsf"
            inputs.ceilingBitsPerSecond = 64_000
            let outcome = PlaybackDecisionPolicy.decide(inputs)
            #expect(outcome.route == route)
            #expect(outcome.reason == .explicitRoute)
        }
    }

    @Test func fallsBackToSubsonicWhenJellyfinCannotTranscode() {
        // The Subsonic endpoint still applies maxBitRate/format, so a ceiling prefers it over a
        // Direct Play that would stall.
        var inputs = capableSource
        inputs.supportsTranscoding = false
        inputs.container = "alac"
        inputs.sourceBitRate = 900_000
        inputs.ceilingBitsPerSecond = 256_000
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .openSubsonic)
        #expect(outcome.reason == .openSubsonicFallback)
    }

    @Test func directStreamOnlyStillCountsAsDirectPlay() {
        var inputs = capableSource
        inputs.supportsDirectPlay = nil
        inputs.container = "mp3"
        let outcome = PlaybackDecisionPolicy.decide(inputs)
        #expect(outcome.route == .directPlay)
        #expect(outcome.reason == .directStreamWithoutTranscoding)
    }

    @Test func serverThatSaysNothingFallsBack() {
        let outcome = PlaybackDecisionPolicy.decide(PlaybackDecisionPolicy.Inputs())
        #expect(outcome.route == .openSubsonic)
        #expect(outcome.reason == .openSubsonicFallback)
    }

    @Test func neverReturnsAutomatic() {
        // The route is consumed directly as a concrete request, so `.automatic` must be impossible.
        var inputs = capableSource
        inputs.container = "alac"
        inputs.codec = "alac"
        #expect(PlaybackDecisionPolicy.decide(inputs).route != .automatic)
    }
}
