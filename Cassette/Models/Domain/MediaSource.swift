// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

nonisolated struct JellyfinPlaybackContext: Sendable {
    let itemID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let playMethod: JellyfinPlayMethod
    let route: JellyfinPlaybackRoute?

    init(itemID: String, mediaSourceID: String?, playSessionID: String?,
         playMethod: JellyfinPlayMethod, route: JellyfinPlaybackRoute? = nil) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.playMethod = playMethod
        self.route = route
    }
}

nonisolated enum MediaSource: Sendable {
    case downloaded(URL, playbackSong: DisplayableSong? = nil)
    case cached(URL, playbackSong: DisplayableSong? = nil)
    /// Remote stream of a finite-duration song. Custom headers must be injected
    /// into every request to reach Cloudflare-protected (or other reverse-proxy) hosts.
    case stream(URL, customHeaders: [String: String], jellyfin: JellyfinPlaybackContext? = nil,
                supportsTranscodeOffset: Bool = false, playbackSong: DisplayableSong? = nil)
    /// Live audio stream (Internet Radio Station). Infinite-duration, not scrubbable,
    /// not cacheable. Custom headers may be required when the radio host is reached
    /// via the user's Navidrome reverse proxy.
    case liveStream(URL, customHeaders: [String: String], stationId: String)

    /// Actual server file identity/audio metadata. The queue and UI keep the requested song.
    var playbackSong: DisplayableSong? {
        switch self {
        case .downloaded(_, let song), .cached(_, let song), .stream(_, _, _, _, let song): return song
        case .liveStream: return nil
        }
    }

    func withPlaybackSong(_ song: DisplayableSong) -> MediaSource {
        switch self {
        case .downloaded(let url, _): return .downloaded(url, playbackSong: song)
        case .cached(let url, _): return .cached(url, playbackSong: song)
        case .stream(let url, let headers, let context, let offset, _):
            return .stream(url, customHeaders: headers, jellyfin: context, supportsTranscodeOffset: offset, playbackSong: song)
        case .liveStream: return self
        }
    }

    var url: URL {
        switch self {
        case .downloaded(let url, _), .cached(let url, _):
            return url
        case .stream(let url, _, _, _, _), .liveStream(let url, _, _):
            return url
        }
    }

    var customHeaders: [String: String] {
        switch self {
        case .downloaded, .cached:
            return [:]
        case .stream(_, let headers, _, _, _), .liveStream(_, let headers, _):
            return headers
        }
    }

    var jellyfinPlaybackContext: JellyfinPlaybackContext? {
        guard case .stream(_, _, let context, _, _) = self else { return nil }
        return context
    }

    var supportsTranscodeOffset: Bool {
        guard case .stream(_, _, _, let supported, _) = self else { return false }
        return supported || isJellyfinProgressiveTranscode || isJellyfinUniversal
    }

    var isJellyfinUniversal: Bool {
        guard case .stream(let url, _, _, _, _) = self else { return false }
        return url.path.lowercased().contains("/audio/") && url.lastPathComponent.lowercased() == "universal"
    }

    private var isJellyfinProgressiveTranscode: Bool {
        guard case .stream(let url, _, _, _, _) = self,
              url.path.lowercased().contains("/audio/"),
              url.lastPathComponent.lowercased().hasPrefix("stream.") else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name.lowercased() == "static" && $0.value?.lowercased() == "false"
        } == true
    }

    /// The server encodes from a media-time offset; byte seeking a growing transcode is unreliable.
    /// Preserve authentication, codec, bitrate and reverse-proxy parameters verbatim.
    func transcodeRequest(at position: TimeInterval) -> (url: URL, offset: TimeInterval)? {
        guard supportsTranscodeOffset, position.isFinite,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let jellyfin = isJellyfinProgressiveTranscode || isJellyfinUniversal
        let offset = max(0, jellyfin ? position : position.rounded(.down))
        guard offset < Double(Int64.max) / 10_000_000 else { return nil }
        let parameter = jellyfin ? "StartTimeTicks" : "timeOffset"
        var query = components.queryItems ?? []
        if isJellyfinUniversal {
            // Universal can return a static file or preserve timestamps. Its offset fallback
            // uses the explicit progressive endpoint so the response has a zero-based clock.
            let codec = query.first { $0.name.lowercased() == "audiocodec" }?.value?.lowercased() ?? "aac"
            let containers = ["aac": "aac", "mp3": "mp3", "opus": "ogg", "flac": "flac", "alac": "m4a"]
            guard let container = containers[codec] else { return nil }
            components.path = (components.path as NSString).deletingLastPathComponent + "/stream.\(container)"
            let bitrate = query.first { $0.name.lowercased() == "audiobitrate" }?.value
                ?? query.first { $0.name.lowercased() == "maxstreamingbitrate" }?.value
            for (name, value) in [("Static", "false"), ("AudioCodec", codec),
                                  ("CopyTimestamps", "false"), ("AllowAudioStreamCopy", "false"),
                                  ("EnableAutoStreamCopy", "false")] {
                query.removeAll { $0.name.lowercased() == name.lowercased() }
                query.append(URLQueryItem(name: name, value: value))
            }
            if let bitrate {
                query.removeAll { $0.name.lowercased() == "audiobitrate" }
                query.append(URLQueryItem(name: "AudioBitRate", value: bitrate))
            }
        }
        query.removeAll { $0.name.lowercased() == parameter.lowercased() }
        query.append(URLQueryItem(name: parameter, value: jellyfin
            ? String(Int64((offset * 10_000_000).rounded(.down))) : String(Int64(offset))))
        components.queryItems = query
        guard let requestURL = components.url else { return nil }
        return (requestURL, offset)
    }

    /// Whether this source represents a live stream (radio) — non-scrubbable, infinite duration.
    var isLiveStream: Bool {
        if case .liveStream = self { return true }
        return false
    }

    /// True when the audio is already on this device, so reading it costs no network.
    var isLocal: Bool {
        switch self {
        case .downloaded, .cached:
            return true
        case .stream, .liveStream:
            return false
        }
    }
}
