import Foundation

/// Safe, presentation-only details of the resolved source. Never exposes authenticated URLs,
/// headers, tokens, or local paths. Requested encoding is not a measurement of decoded audio.
nonisolated struct PlaybackDetails: Sendable, Equatable {
    enum Location: String, Sendable { case downloaded = "Downloaded file", cached = "Cached file", server = "Server stream", radio = "Internet radio" }
    enum Method: String, Sendable {
        case local = "Local playback"
        case directPlay = "Direct Play"
        case universalTranscoding = "Universal Transcoding"
        case hls = "HLS"
        case originalFile = "Original File"
        case openSubsonic = "OpenSubsonic"
        case serverDefault = "Server-selected stream"
        case radio = "Live streaming"

        var usesOriginalName: Bool {
            switch self {
            case .directPlay, .universalTranscoding, .hls, .originalFile, .openSubsonic: true
            case .local, .serverDefault, .radio: false
            }
        }

        static func from(_ route: JellyfinPlaybackRoute) -> Self? {
            switch route {
            case .directPlay: .directPlay
            case .universal: .universalTranscoding
            case .hls: .hls
            case .originalFile: .originalFile
            case .openSubsonic: .openSubsonic
            case .automatic: nil
            }
        }
    }

    let location: Location
    let method: Method
    let engine: String
    let requestedCodec: String?
    let bitRateLimitKbps: Int?
    let localFileFormat: String?
    let actualCodec: String?
    var audioSessionSampleRate: Double?
    var replayGainStatus: PlaybackGainState.Status = .disabled
    var requestedGainDB: Float = 0
    var appliedGainDB: Float = 0

    init(source: MediaSource, usesSystemPlayer: Bool, actualCodec: String? = nil) {
        self.actualCodec = actualCodec
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
            if let route = source.jellyfinPlaybackContext?.route, let resolved = Method.from(route) {
                method = resolved
            } else if source.url.pathExtension.lowercased() == "m3u8" {
                method = .hls
            } else if path.contains("/rest/"), ["stream", "stream.view"].contains(source.url.lastPathComponent.lowercased()) {
                method = .openSubsonic
            } else if path.contains("/items/"), path.hasSuffix("/file") {
                method = .originalFile
            } else if value("Static") == "true"
                        || source.jellyfinPlaybackContext?.playMethod == .directPlay
                        || source.jellyfinPlaybackContext?.playMethod == .directStream {
                method = .directPlay
            } else if source.jellyfinPlaybackContext?.playMethod == .transcode
                        || value("AudioCodec") != nil || path.hasSuffix("/universal")
                        || (path.contains("/audio/") && source.url.lastPathComponent.lowercased().hasPrefix("stream.") && value("Static") == "false") {
                // The app's Universal route also uses progressive stream.{codec} URLs.
                method = .universalTranscoding
            } else if format != nil {
                method = .openSubsonic
            } else {
                method = .serverDefault
            }
            requestedCodec = method == .directPlay || method == .originalFile ? nil : codec?.uppercased()
            let limit = value("MaxStreamingBitrate").flatMap(Int.init).map { $0 / 1_000 }
                ?? value("maxBitRate").flatMap(Int.init)
            bitRateLimitKbps = limit.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}
