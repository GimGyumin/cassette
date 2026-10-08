// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

nonisolated extension JellyfinMediaSource {
    /// The audio stream a decision should look at: the default one when the server marks it,
    /// otherwise the first audio stream. Containers and codecs live here, not on the source.
    var defaultAudioStream: JellyfinMediaStream? {
        let audio = mediaStreams?.filter {
            ($0.type ?? "").caseInsensitiveCompare("Audio") == .orderedSame
        } ?? []
        return audio.first { $0.isDefault == true } ?? audio.first
    }
}

/// Pure decision for the Jellyfin "Automatic" playback method.
///
/// Jellyfin's own model is: the client posts what it can decode and what the connection allows, and
/// the server answers Direct Play or Transcoding. Navidrome only implements part of that API, so the
/// client cannot hand the decision over — it has to combine three inputs itself, which is exactly
/// what this type does:
///
/// 1. what the returned `MediaSource` says (`SupportsDirectPlay`, `SupportsTranscoding`, bitrate,
///    container, codec),
/// 2. whether this app can decode that container/codec (`iOSAudioCapability`),
/// 3. the current bitrate ceiling for this connection (`AdaptiveQualityPolicy` / the user's quality).
///
/// It never returns `.automatic` and never overrides a route a caller explicitly asked for: the app
/// always requests `.automatic` because there is no playback-method setting any more, but a future
/// caller that pins Direct Play, Universal, HLS, Original File or OpenSubsonic gets that route back.
nonisolated enum PlaybackDecisionPolicy {
    /// A playable original needs no PlaybackInfo negotiation or server transcode startup.
    static func canStreamOriginalImmediately(format: CacheFormat, song: DisplayableSong?) -> Bool {
        guard format == .flacOriginal, let song else { return false }
        let container = iOSAudioCapability.normalize(song.audioFormat)
            ?? iOSAudioCapability.container(forContentType: song.contentType)
        return iOSAudioCapability.canDecodeDirectly(container: container, codec: nil,
            sampleRate: song.samplingRate, bitDepth: song.bitDepth)
    }

    /// Why a route was chosen. Logged verbatim (`[ROUTE] … reason=`) so a device log explains itself.
    nonisolated enum Reason: String, Equatable, Sendable {
        case explicitRoute
        case bitstream
        case localFile
        case directPlayFits
        case directPlayOverCeiling
        case directPlayUnsupportedCodec
        case serverRequiresTranscoding
        case directStreamWithoutTranscoding
        case openSubsonicFallback
    }

    nonisolated struct Outcome: Equatable, Sendable {
        let route: JellyfinPlaybackRoute
        let reason: Reason
    }

    nonisolated struct Inputs: Equatable, Sendable {
        /// The route the user selected. `.automatic` means "you decide".
        var requestedRoute: JellyfinPlaybackRoute = .automatic
        var supportsDirectPlay: Bool?
        var supportsDirectStream: Bool?
        var supportsTranscoding: Bool?
        /// Only use segmented delivery when PlaybackInfo actually offers it.
        var supportsHLSTranscoding: Bool = false
        /// Source bitrate in bits per second, when the server reported it.
        var sourceBitRate: Int?
        var container: String?
        var codec: String?
        var sampleRate: Int?
        var bitDepth: Int?
        /// Bits per second this connection/quality may use. `nil` = no known ceiling.
        var ceilingBitsPerSecond: Int?
        /// Dolby / Atmos / multichannel: transcoding would destroy the bitstream.
        var requiresBitstream: Bool = false
        /// Downloaded file: no network decision to make.
        var sourceIsLocal: Bool = false
        /// Preserve the original; Jellyfin's transcode and HLS routes are lossy.
        var preferLossless: Bool = false
        /// An explicit lossy output format must not be satisfied by a raw Direct Play.
        var requiresLossyEncoding: Bool = false
    }

    static func decide(_ inputs: Inputs) -> Outcome {
        // 1. An explicit route is an instruction — never overridden.
        if inputs.requestedRoute != .automatic {
            return Outcome(route: inputs.requestedRoute, reason: .explicitRoute)
        }
        // 2. A Dolby/Atmos/multichannel bitstream must reach the engine untouched.
        if inputs.requiresBitstream {
            return Outcome(route: .directPlay, reason: .bitstream)
        }
        // 3. A downloaded file is already on disk.
        if inputs.sourceIsLocal {
            return Outcome(route: .directPlay, reason: .localFile)
        }

        if inputs.requiresLossyEncoding {
            return Outcome(route: inputs.supportsTranscoding == true
                ? (inputs.supportsHLSTranscoding ? .hls : .universal)
                : .openSubsonic,
                reason: inputs.supportsTranscoding == true ? .serverRequiresTranscoding : .openSubsonicFallback)
        }

        // A lossless setting is an original-file request. PlaybackInfo may advertise a
        // transcode, but this server's Universal/HLS outputs cannot satisfy that setting.
        // Unknown or unsupported originals use the OpenSubsonic raw endpoint instead.
        if inputs.preferLossless {
            let decodableOriginal = iOSAudioCapability.canDecodeDirectly(
                container: inputs.container, codec: inputs.codec,
                sampleRate: inputs.sampleRate, bitDepth: inputs.bitDepth
            )
            if decodableOriginal && (inputs.supportsDirectPlay == true || inputs.supportsDirectStream == true) {
                return Outcome(route: .directPlay, reason: .directPlayFits)
            }
            return Outcome(route: .openSubsonic, reason: .openSubsonicFallback)
        }

        let decodable = iOSAudioCapability.canDecodeDirectly(
            container: inputs.container,
            codec: inputs.codec,
            sampleRate: inputs.sampleRate,
            bitDepth: inputs.bitDepth
        )
        let fits = fitsWithinCeiling(
            sourceBitRate: inputs.sourceBitRate,
            container: inputs.container,
            ceilingBitsPerSecond: inputs.ceilingBitsPerSecond
        )

        // Asked to play something we cannot decode, or something that will not fit the connection.
        if !decodable || !fits {
            let reason: Reason = decodable ? .directPlayOverCeiling : .directPlayUnsupportedCodec
            if inputs.supportsTranscoding == true {
                return Outcome(route: inputs.supportsHLSTranscoding ? .hls : .universal, reason: reason)
            }
            // This Jellyfin route cannot transcode. The Subsonic endpoint still applies
            // `maxBitRate`/`format`, which is exactly what a ceiling needs.
            return Outcome(route: .openSubsonic, reason: .openSubsonicFallback)
        }

        if inputs.supportsDirectPlay == true {
            return Outcome(route: .directPlay, reason: .directPlayFits)
        }
        // Direct Stream still serves the original bytes; it is the best available when the server
        // will neither Direct Play nor transcode.
        if inputs.supportsDirectStream == true {
            return Outcome(route: .directPlay, reason: .directStreamWithoutTranscoding)
        }
        if inputs.supportsTranscoding == true {
            return Outcome(route: inputs.supportsHLSTranscoding ? .hls : .universal,
                           reason: .serverRequiresTranscoding)
        }
        return Outcome(route: .openSubsonic, reason: .openSubsonicFallback)
    }

    /// Which endpoint resolves a song's audio.
    ///
    /// The playback method is not user-selectable: a server that exposes the Jellyfin feature and a
    /// song that carries a Jellyfin-mapped ID go through `PlaybackInfo` — where Direct Play vs a
    /// server-side transcode is decided per resolve — while every other song keeps the OpenSubsonic
    /// endpoint, which is also the only one that reuses the ephemeral cache.
    static func usesJellyfinTransport(hasJellyfinService: Bool, jellyfinItemID: String?) -> Bool {
        hasJellyfinService && jellyfinItemID != nil
    }

    /// Whether the original stream can be carried inside `ceilingBitsPerSecond`.
    ///
    /// A missing source bitrate is judged by container: a lossless container cannot be assumed to fit
    /// a tight ceiling (the "ALAC 900 kbps under a 256 kbps cap" case), while a lossy or unknown one
    /// can — refusing to ever Direct Play on cellular would cost quality on a fast 5G link.
    static func fitsWithinCeiling(
        sourceBitRate: Int?,
        container: String?,
        ceilingBitsPerSecond: Int?
    ) -> Bool {
        guard let ceilingBitsPerSecond, ceilingBitsPerSecond > 0 else { return true }
        if let sourceBitRate, sourceBitRate > 0 {
            return sourceBitRate <= ceilingBitsPerSecond
        }
        guard let container = iOSAudioCapability.normalize(container) else { return true }
        return !iOSAudioCapability.losslessContainers.contains(container)
    }
}
