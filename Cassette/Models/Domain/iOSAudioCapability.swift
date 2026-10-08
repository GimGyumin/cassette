// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// What this app can decode without asking the server to transcode.
///
/// Jellyfin's Automatic decision is supposed to be driven by a device profile the client sends, but
/// Navidrome's Jellyfin compatibility layer only implements part of it — so the same knowledge is
/// also needed locally, to decide whether a returned `MediaSource` may be handed to the engines as
/// is. The set below is the union of what the two engines in this app can play:
/// `AudioStreaming` (MP3, AAC/M4A, FLAC, WAV, Ogg/Vorbis) and AVFoundation via `AVPlayer`
/// (ALAC, AAC, MP3, FLAC, PCM, spatial/multichannel).
///
/// Anything unrecognised is treated as **not** directly playable: asking the server to transcode is
/// a small cost, handing the engine bytes it cannot decode is a failed track.
nonisolated enum iOSAudioCapability {

    /// Containers accepted as-is. Values are normalised (lowercased, no leading dot, first token).
    static let directPlayContainers: Set<String> = [
        "alac", "m4a", "mp4", "flac", "mp3", "aac",
        "wav", "wave", "aif", "aiff", "caf",
        "ogg", "oga", "opus",
    ]

    /// Codecs accepted as-is (as reported by `MediaStream.codec`).
    static let directPlayCodecs: Set<String> = [
        "alac", "flac", "aac", "mp3", "pcm", "pcm_s16le", "pcm_s24le",
        "vorbis", "opus", "ac3", "eac3",
    ]

    /// Containers that are lossless by definition. Used when the server omits the source bitrate:
    /// these cannot be assumed to fit a cellular ceiling, while a lossy container can.
    static let losslessContainers: Set<String> = [
        "alac", "flac", "wav", "wave", "aif", "aiff", "caf", "dsf", "dff", "ape", "wv", "tak",
    ]

    static let maximumSampleRate = 192_000
    static let maximumBitDepth = 24

    /// Container/codec pairs advertised in the Jellyfin `DeviceProfile`.
    static let directPlayPairs: [(container: String, codec: String)] = [
        ("alac", "alac"),
        ("m4a", "alac"),
        ("m4a", "aac"),
        ("mp4", "aac"),
        ("flac", "flac"),
        ("mp3", "mp3"),
        ("wav", "pcm"),
        ("aiff", "pcm"),
        ("ogg", "vorbis"),
        ("opus", "opus"),
    ]

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? value
        let normalized = token
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Some Jellyfin-compatible responses omit `suffix` but still include a MIME type.
    /// Use only known audio types; an arbitrary `audio/*` value is not proof we can decode it.
    static func container(forContentType value: String?) -> String? {
        guard let mime = value?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch mime {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/alac": return "alac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        default: return nil
        }
    }

    /// True when the engines can decode this stream directly.
    ///
    /// A missing container **and** codec means the server told us nothing usable, which is not a
    /// licence to guess: the caller should transcode instead.
    static func canDecodeDirectly(
        container: String?,
        codec: String?,
        sampleRate: Int?,
        bitDepth: Int?
    ) -> Bool {
        let container = normalize(container)
        let codec = normalize(codec)
        guard container != nil || codec != nil else { return false }
        if let container, !directPlayContainers.contains(container) { return false }
        if let codec, !directPlayCodecs.contains(codec) { return false }
        if let sampleRate, sampleRate > maximumSampleRate { return false }
        if let bitDepth, bitDepth > maximumBitDepth { return false }
        return true
    }

    /// Device profile advertised to the server, so a Jellyfin implementation that *does* honour it
    /// answers the Direct Play question correctly on its own.
    static func deviceProfile(maxStreamingBitrate: Int?, preferLossless: Bool = false) -> JellyfinPlaybackInfoRequest.DeviceProfile {
        JellyfinPlaybackInfoRequest.DeviceProfile(
            Name: "Cassette",
            MaxStreamingBitrate: maxStreamingBitrate,
            DirectPlayProfiles: directPlayPairs.map {
                JellyfinPlaybackInfoRequest.DeviceProfile.DirectPlayProfile(
                    Container: $0.container,
                    AudioCodec: $0.codec
                )
            },
            TranscodingProfiles: preferLossless ? [] : [
                .init(Container: "ts", AudioCodec: "aac", transport: "hls", Context: "Streaming", MaxAudioChannels: "2"),
                .init(Container: "aac", AudioCodec: "aac", transport: "http", Context: "Streaming", MaxAudioChannels: "2"),
                .init(Container: "mp3", AudioCodec: "mp3", transport: "http", Context: "Streaming", MaxAudioChannels: "2"),
                .init(Container: "opus", AudioCodec: "opus", transport: "http", Context: "Streaming", MaxAudioChannels: "2"),
            ]
        )
    }
}
