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
}

nonisolated enum MediaSource: Sendable {
    case downloaded(URL)
    case cached(URL)
    /// Remote stream of a finite-duration song. Custom headers must be injected
    /// into every request to reach Cloudflare-protected (or other reverse-proxy) hosts.
    case stream(URL, customHeaders: [String: String], jellyfin: JellyfinPlaybackContext? = nil,
                supportsTranscodeOffset: Bool = false)
    /// Live audio stream (Internet Radio Station). Infinite-duration, not scrubbable,
    /// not cacheable. Custom headers may be required when the radio host is reached
    /// via the user's Navidrome reverse proxy.
    case liveStream(URL, customHeaders: [String: String], stationId: String)

    var url: URL {
        switch self {
        case .downloaded(let url), .cached(let url):
            return url
        case .stream(let url, _, _, _), .liveStream(let url, _, _):
            return url
        }
    }

    var customHeaders: [String: String] {
        switch self {
        case .downloaded, .cached:
            return [:]
        case .stream(_, let headers, _, _), .liveStream(_, let headers, _):
            return headers
        }
    }

    var jellyfinPlaybackContext: JellyfinPlaybackContext? {
        guard case .stream(_, _, let context, _) = self else { return nil }
        return context
    }

    var supportsTranscodeOffset: Bool {
        guard case .stream(_, _, _, let supported) = self else { return false }
        return supported || isJellyfinProgressiveTranscode
    }

    private var isJellyfinProgressiveTranscode: Bool {
        guard case .stream(let url, _, _, _) = self,
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
        let jellyfin = isJellyfinProgressiveTranscode
        let offset = max(0, jellyfin ? position : position.rounded(.down))
        guard offset < Double(Int64.max) / 10_000_000 else { return nil }
        let parameter = jellyfin ? "StartTimeTicks" : "timeOffset"
        var query = components.queryItems ?? []
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
