// SwiftSonicClient+Lyrics.swift — SwiftSonic
//
// Lyrics endpoints: plain-text and structured (OpenSubsonic songLyrics extension).

import Foundation

extension SwiftSonicClient {

    public func getLyrics(artist: String? = nil, title: String? = nil) async throws -> Lyrics? {
        var params: [String: String] = [:]
        if let artist { params["artist"] = artist }
        if let title  { params["title"]  = title  }

        let envelope: SubsonicEnvelope<LyricsPayload> =
            try await performDecode(endpoint: "getLyrics", params: params)

        guard let lyrics = envelope.payload?.lyrics,
              let value  = lyrics.value, !value.isEmpty else {
            return nil
        }
        return lyrics
    }

    /// - Parameter enhanced: Request songLyrics v2 karaoke / kind / agents (Navidrome 0.63+).
    public func getLyricsBySongId(id: String, enhanced: Bool = false) async throws -> LyricsList {
        var params: [String: String] = ["id": id]
        if enhanced {
            params["enhanced"] = "true"
        }
        let envelope: SubsonicEnvelope<LyricsListPayload> =
            try await performDecode(endpoint: "getLyricsBySongId", params: params)
        return try unwrapRequired(envelope.payload?.lyricsList, endpoint: "getLyricsBySongId")
    }
}

struct LyricsPayload: SubsonicPayload {
    static let payloadKey = "lyrics"
    let lyrics: Lyrics
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        lyrics = try container.decode(Lyrics.self)
    }
}

struct LyricsListPayload: SubsonicPayload {
    static let payloadKey = "lyricsList"
    let lyricsList: LyricsList
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        lyricsList = try container.decode(LyricsList.self)
    }
}
