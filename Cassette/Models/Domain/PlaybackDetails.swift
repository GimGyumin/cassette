import Foundation

/// Safe, presentation-only details of the resolved source. Never exposes authenticated URLs,
/// headers, tokens, or local paths. Requested encoding is not a measurement of decoded audio.
nonisolated struct PlaybackDetails: Sendable, Equatable {
    enum Location: String, Sendable { case downloaded = "Downloaded file", cached = "Cached file", server = "Server stream", radio = "Internet radio" }
    enum Method: String, Sendable { case local = "Local playback", original = "Original playback", converted = "Server conversion", hls = "HLS streaming", serverDefault = "Server-selected stream", radio = "Live streaming" }

    let location: Location
    let method: Method
    let engine: String
    let requestedCodec: String?
    let bitRateLimitKbps: Int?
    let localFileFormat: String?

    init(source: MediaSource, usesSystemPlayer: Bool) {
        engine = usesSystemPlayer ? "AVPlayer" : "AudioStreaming"
        let query = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value?.lowercased()
        }
        let format = value("format")
        let codec = value("AudioCodec") ?? (format == "raw" ? nil : format)
        let path = source.url.path.lowercased()
        switch source {
        case .downloaded, .cached:
            if case .downloaded = source { location = .downloaded } else { location = .cached }
            method = .local
            let suffix = source.url.pathExtension.lowercased()
            localFileFormat = ["flac", "alac", "m4a", "mp3", "aac", "opus", "ogg", "wav", "aiff", "caf", "ac3", "eac3"].contains(suffix) ? suffix.uppercased() : nil
            requestedCodec = nil
            bitRateLimitKbps = nil
        case .liveStream:
            location = .radio
            method = .radio
            localFileFormat = nil
            requestedCodec = nil
            bitRateLimitKbps = nil
        case .stream:
            location = .server
            localFileFormat = nil
            if source.url.pathExtension.lowercased() == "m3u8" {
                method = .hls
            } else if source.jellyfinPlaybackContext?.playMethod == .transcode {
                method = .converted
            } else if format == "raw" || value("Static") == "true"
                        || (path.contains("/items/") && path.hasSuffix("/file"))
                        || source.jellyfinPlaybackContext?.playMethod == .directPlay
                        || source.jellyfinPlaybackContext?.playMethod == .directStream {
                method = .original
            } else if codec != nil || path.hasSuffix("/universal") {
                method = .converted
            } else {
                method = .serverDefault
            }
            requestedCodec = method == .original ? nil : codec?.uppercased()
            let limit = value("MaxStreamingBitrate").flatMap(Int.init).map { $0 / 1_000 }
                ?? value("maxBitRate").flatMap(Int.init)
            bitRateLimitKbps = limit.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}
