// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

private nonisolated struct JellyfinResolvedStream: Sendable {
    let url: URL
    let context: JellyfinPlaybackContext
    /// The route that produced this URL, so the caller can log the decision once.
    let route: JellyfinPlaybackRoute
    let reason: PlaybackDecisionPolicy.Reason
}

/// Single entry point for obtaining a playable URL for a given song.
/// Resolution order: downloaded → cached → stream.
/// PlayerService always calls this — it never contacts SwiftSonic directly.
actor MediaResolver: MediaResolverProtocol {
    private let downloadService: any DownloadServiceProtocol
    private let cacheService: any CacheServiceProtocol
    private let serverService: any ServerServiceProtocol
    private let serverState: ServerState
    private let streamingSettings: StreamingSettings
    private let mediaIdentityService: MediaIdentityService?
    private let jellyfinService: JellyfinService?
    private let speedProbe: NetworkSpeedProbe?

    init(
        downloadService: any DownloadServiceProtocol,
        cacheService: any CacheServiceProtocol,
        serverService: any ServerServiceProtocol,
        serverState: ServerState,
        streamingSettings: StreamingSettings,
        mediaIdentityService: MediaIdentityService? = nil,
        jellyfinService: JellyfinService? = nil,
        speedProbe: NetworkSpeedProbe? = nil
    ) {
        self.downloadService = downloadService
        self.cacheService = cacheService
        self.serverService = serverService
        self.serverState = serverState
        self.streamingSettings = streamingSettings
        self.mediaIdentityService = mediaIdentityService
        self.jellyfinService = jellyfinService
        self.speedProbe = speedProbe
    }

    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        try Task.checkCancellation()
        // Local files take priority over network routing and quality preferences. The stores
        // validate availability; a lossless preference must not trigger another download.
        if let url = await downloadService.downloadedURL(forSongId: songId, serverId: serverId) {
            try Task.checkCancellation()
            return .downloaded(url)
        }
        if let url = await cacheService.cachedURL(forSongId: songId, serverId: serverId) {
            try Task.checkCancellation()
            await cacheService.touch(songId: songId, serverId: serverId)
            return .cached(url)
        }
        let isOnline = await MainActor.run { serverState.isOnline }
        guard isOnline else { throw CassetteError.offlineUnavailable(songId: songId) }

        let currentSongID = await MainActor.run {
            mediaIdentityService?.resolveCurrentID(songId, serverId: serverId, entityType: .song) ?? songId
        }
        let preserveBitstream = song.map { AudioQualityClassifier.shouldSkipTranscoding($0) } ?? false
        // The playback method is not a setting any more, so there is no stored route to read:
        // `PlaybackDecisionPolicy` derives Direct Play vs a server transcode per resolve from the
        // configured quality, the current network and the source itself.
        let jellyfinItemID = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: currentSongID)
        // Whether this song is fetched through Jellyfin's PlaybackInfo route at all — a server
        // capability plus a Jellyfin-mapped ID, not a user choice. Local files have already
        // been resolved above; this decision applies only when streaming is needed.
        let usesJellyfinTransport = PlaybackDecisionPolicy.usesJellyfinTransport(
            hasJellyfinService: jellyfinService != nil,
            jellyfinItemID: jellyfinItemID
        )

        // Which *quality policy* applies is a network-cost question, not a throughput question:
        // metered (cellular/hotspot) or Low Data Mode is what entitles the app to fall back to the
        // cellular format. A single slow measurement must not do that on Wi-Fi — it
        // only caps the stream below — otherwise a healthy home Wi-Fi link silently played lossy.
        let (usesCellularQuality, isLimited, configuredFormat) = await MainActor.run {
            let metered = serverState.isExpensive || serverState.isNetworkConstrained
            let limited = serverState.isLimitedNetwork
            return (metered, limited, streamingSettings.formatForCurrentNetwork(isLimited: metered))
        }

        // Playback must never wait for a second GET of the same audio just to measure it.
        // Reuse a known measurement; unknown links start at the user's network-specific quality.
        // Sustained playback failures can lower Automatic for subsequent resolutions.
        let ceiling = await MainActor.run { streamingSettings.currentAdaptiveCeiling(isLimited: usesCellularQuality) }
        let applyCeilingToExplicitChoice = await MainActor.run {
            streamingSettings.adaptiveCeilingAppliesToExplicitChoice
        }
        let measuredRate = await speedProbe?.freshRate(serverId: serverId)
        try Task.checkCancellation()
        let effectiveFormat = AdaptiveQualityPolicy.effectiveFormat(
            configured: configuredFormat,
            sourceBitRateKbps: song?.bitRate,
            measuredBytesPerSecond: measuredRate,
            ceiling: ceiling,
            isLimitedNetwork: usesCellularQuality,
            applyCeilingToExplicitChoice: applyCeilingToExplicitChoice
        )
        let streamFormat = AdaptiveQualityPolicy.transportFormat(effectiveFormat)
        try Task.checkCancellation()
        let client = try await serverService.makeSwiftSonicClient()
        let credentials = try await serverService.activeCredentials()
        try Task.checkCancellation()
        // Direct originals avoid capability/authentication/PlaybackInfo round trips and cannot
        // inherit a Jellyfin universal endpoint's default AAC encoder. Cache hits still win above.
        if PlaybackDecisionPolicy.canStreamOriginalImmediately(format: streamFormat, song: song),
           let url = client.streamURL(id: currentSongID, maxBitRate: nil, format: "raw") {
            Logger.resolver.info("[ROUTE] original stream without negotiation id=\(currentSongID, privacy: .public)")
            return .stream(url, customHeaders: credentials.customHeaders)
        }
        // The bitrate this connection may actually use, in bit/s. It travels to the server as
        // `MaxStreamingBitrate` so a Jellyfin implementation answers Direct Play vs Transcoding for
        // *this* link, and it is also the ceiling the client-side decision checks against.
        let ceilingKbps = AdaptiveQualityPolicy.streamingCeilingKbps(
            configured: streamFormat,
            sourceBitRateKbps: song?.bitRate,
            measuredBytesPerSecond: measuredRate,
            isLimitedNetwork: usesCellularQuality
        )
        let ceilingBitsPerSecond = ceilingKbps.map { Int($0 * 1_000) }
        // One line that explains the whole decision: with it, "Automatic played a lossy stream" is
        // answerable from a device log without re-deriving the policy.
        Logger.resolver.info(
            "[QUALITY] '\(currentSongID, privacy: .public)' configured=\(configuredFormat.rawValue, privacy: .public) source=\(song?.bitRate ?? -1, privacy: .public)kbps measured=\(measuredRate.map { Int($0) } ?? -1, privacy: .public)B/s meteredOrConstrained=\(usesCellularQuality, privacy: .public) → format=\(streamFormat.rawValue, privacy: .public) ceilingKbps=\(ceilingKbps.map { Int($0) } ?? -1, privacy: .public) (limitedNetwork=\(isLimited, privacy: .public))"
        )

        // A concrete lossy format is already a complete route decision. Going through
        // PlaybackInfo first costs a round trip and Navidrome can omit MediaSources,
        // making an otherwise valid conversion look like an unknown raw source.
        if streamFormat != .flacOriginal, !preserveBitstream,
           let format = streamFormat.subsonicFormat,
           let url = client.streamURL(id: currentSongID,
                                      maxBitRate: streamFormat.subsonicMaxBitRate,
                                      format: format) {
            Logger.resolver.info("[ROUTE] '\(currentSongID, privacy: .public)' → requested \(format, privacy: .public) transcode")
            let source = MediaSource.stream(url, customHeaders: credentials.customHeaders)
            if source.supportsTranscodeOffset { return source }
            let capabilities = try? await client.loadCapabilities()
            try Task.checkCancellation()
            return .stream(url, customHeaders: credentials.customHeaders,
                           supportsTranscodeOffset: capabilities?.supports("transcodeOffset") == true)
        }

        if usesJellyfinTransport, let jellyfinService, let jellyfinID = jellyfinItemID {
            // Carrying the constraints is the point: an empty PlaybackInfo body makes the server
            // answer "Direct Play is fine" for a lossless original even on a 1 Mbps link.
            let constraints = JellyfinPlaybackInfoRequest(
                MaxStreamingBitrate: ceilingBitsPerSecond,
                DeviceProfile: iOSAudioCapability.deviceProfile(maxStreamingBitrate: ceilingBitsPerSecond, preferLossless: streamFormat == .flacOriginal)
            )
            do {
                let resolved = try await jellyfinService.perform(feature: .playbackInfo) { jellyfinClient -> JellyfinResolvedStream? in
                    let playbackInfo = try await jellyfinClient.playbackInfo(
                        itemID: jellyfinID,
                        request: constraints
                    )
                    try Task.checkCancellation()
                    let mediaSource = playbackInfo.mediaSources.first
                    let audioStream = mediaSource?.defaultAudioStream
                    let outcome = PlaybackDecisionPolicy.decide(PlaybackDecisionPolicy.Inputs(
                        // Always Automatic: the setting is gone, so Direct Play vs transcode is
                        // decided here instead of being ordered by the user.
                        requestedRoute: .automatic,
                        supportsDirectPlay: mediaSource?.supportsDirectPlay,
                        supportsDirectStream: mediaSource?.supportsDirectStream,
                        supportsTranscoding: mediaSource?.supportsTranscoding,
                        supportsHLSTranscoding: mediaSource?.transcodingSubProtocol?.lowercased() == "hls"
                            && mediaSource?.transcodingURL != nil,
                        sourceBitRate: mediaSource?.bitrate,
                        container: mediaSource?.container,
                        codec: audioStream?.codec,
                        sampleRate: audioStream?.sampleRate,
                        bitDepth: audioStream?.bitDepth,
                        ceilingBitsPerSecond: ceilingBitsPerSecond,
                        requiresBitstream: preserveBitstream,
                        sourceIsLocal: false,
                        preferLossless: streamFormat == .flacOriginal,
                        requiresLossyEncoding: streamFormat != .flacOriginal
                    ))
                    let requestedRoute = outcome.route

                    let codec = Self.jellyfinCodec(for: streamFormat)
                    let bitrate = ceilingBitsPerSecond ?? streamFormat.subsonicMaxBitRate.map { $0 * 1_000 }
                    let url: URL?
                    let playMethod: JellyfinPlayMethod
                    switch requestedRoute {
                    case .directPlay:
                        url = jellyfinClient.directStreamURL(
                            itemID: jellyfinID,
                            container: mediaSource?.container,
                            mediaSourceID: mediaSource?.id,
                            playSessionID: playbackInfo.playSessionId
                        )
                        playMethod = mediaSource?.supportsDirectPlay == true ? .directPlay : .directStream
                    case .universal:
                        // `static=true` would ask the server to serve the file untouched, which
                        // defeats the whole point of Universal Transcoding.
                        url = jellyfinClient.progressiveAudioURL(
                            itemID: jellyfinID,
                            container: Self.jellyfinContainer(for: streamFormat),
                            audioCodec: codec,
                            audioBitRate: bitrate,
                            mediaSourceID: mediaSource?.id,
                            playSessionID: playbackInfo.playSessionId
                        )
                        playMethod = .transcode
                    case .hls:
                        // Preserve the server's segment/session/codec parameters. A hand-built URL
                        // can restart a different transcode or discard the negotiated profile.
                        url = mediaSource?.transcodingURL.flatMap { jellyfinClient.transcodingStreamURL($0) }
                            ?? jellyfinClient.hlsURL(
                            itemID: jellyfinID,
                            audioCodec: codec,
                            maxStreamingBitrate: bitrate,
                            mediaSourceID: mediaSource?.id,
                            playSessionID: playbackInfo.playSessionId
                        )
                        playMethod = .transcode
                    case .originalFile:
                        url = jellyfinClient.originalFileURL(
                            itemID: jellyfinID,
                            mediaSourceID: mediaSource?.id,
                            playSessionID: playbackInfo.playSessionId
                        )
                        playMethod = .directPlay
                    case .automatic, .openSubsonic:
                        return nil
                    }
                    guard let url else { return nil }
                    return JellyfinResolvedStream(
                        url: url,
                        context: JellyfinPlaybackContext(
                            itemID: jellyfinID,
                            mediaSourceID: mediaSource?.id,
                            playSessionID: playbackInfo.playSessionId,
                            playMethod: playMethod
                        ),
                        route: requestedRoute,
                        reason: outcome.reason
                    )
                }
                try Task.checkCancellation()
                if let resolved {
                    Logger.resolver.info(
                        "[ROUTE] '\(currentSongID, privacy: .public)' → \(resolved.route.rawValue, privacy: .public) (reason=\(resolved.reason.rawValue, privacy: .public), ceiling=\(ceilingBitsPerSecond ?? -1, privacy: .public)bps, limited=\(isLimited, privacy: .public))"
                    )
                    return .stream(
                        resolved.url,
                        customHeaders: credentials.customHeaders,
                        jellyfin: resolved.context
                    )
                }
                Logger.resolver.debug(
                    "[ROUTE] '\(currentSongID, privacy: .public)' → OpenSubsonic fallback (no Jellyfin stream resolved, ceiling=\(ceilingBitsPerSecond ?? -1, privacy: .public)bps)"
                )
            } catch {
                try Task.checkCancellation()
                Logger.resolver.debug(
                    "Jellyfin playback route unavailable for '\(currentSongID, privacy: .public)' — falling back to OpenSubsonic: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        try Task.checkCancellation()
        var maxBitRate = streamFormat.subsonicMaxBitRate
        var format = streamFormat.subsonicFormat

        if preserveBitstream {
            maxBitRate = nil
            format = "raw"
            Logger.resolver.info(
                "Skipping transcode for Dolby/multichannel '\(songId, privacy: .public)' (channels=\(song?.channelCount ?? 0), bitRate=\(song?.bitRate ?? 0))"
            )
        }

        guard let streamURL = client.streamURL(id: currentSongID, maxBitRate: maxBitRate, format: format) else {
            throw CassetteError.mediaNotFound(songId: currentSongID)
        }
        Logger.resolver.debug(
            "Resolved '\(currentSongID, privacy: .public)' as stream (limited=\(isLimited, privacy: .public), format=\(format ?? "default", privacy: .public), measured=\(measuredRate.map { Int($0) } ?? -1, privacy: .public)B/s)"
        )
        return .stream(streamURL, customHeaders: credentials.customHeaders)
    }

    private nonisolated static func jellyfinCodec(for format: CacheFormat) -> String {
        switch format {
        case .aac256, .aac128: return "aac"
        case .mp3_320, .mp3_192: return "mp3"
        case .opus_128: return "opus"
        case .flacOriginal, .matchStream: return "flac"
        }
    }

    private nonisolated static func jellyfinContainer(for format: CacheFormat) -> String {
        switch format {
        // ADTS AAC can be decoded before encoding finishes. A progressive MP4 may put its
        // index at EOF, forcing a range request or a whole-file wait before audio is available.
        case .aac256, .aac128: return "aac"
        case .mp3_320, .mp3_192: return "mp3"
        case .opus_128: return "opus"
        case .flacOriginal, .matchStream: return "flac"
        }
    }

    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource {
        try Task.checkCancellation()
        guard let url = URL(string: station.streamUrl) else {
            Logger.resolver.error("Invalid stream URL for radio station '\(station.id, privacy: .public)': \(station.streamUrl, privacy: .private)")
            throw CassetteError.mediaNotFound(songId: station.id)
        }

        let isOnline = await MainActor.run { serverState.isOnline }
        guard isOnline else {
            Logger.resolver.warning("Radio '\(station.id, privacy: .public)' not available offline.")
            throw CassetteError.offlineUnavailable(songId: station.id)
        }

        let creds = try await serverService.activeCredentials()
        Logger.resolver.debug("Resolved radio '\(station.id, privacy: .public)' as live stream.")
        return .liveStream(url, customHeaders: creds.customHeaders, stationId: station.id)
    }
}
