// Lyrics.swift — SwiftSonic
//
// Data models for song lyrics.
//
// Lyrics      — plain-text lyrics returned by the legacy getLyrics endpoint.
// LyricsList  — structured (optionally time-synced) lyrics returned by the
//               OpenSubsonic getLyricsBySongId endpoint (songLyrics extension).
//
// songLyrics v2 (enhanced=true) adds kind, agents, and cueLine karaoke timing.

import Foundation

// MARK: - Lyrics (legacy)

/// Song lyrics returned by ``SwiftSonicClient/getLyrics(artist:title:)``.
public struct Lyrics: Decodable, Sendable {

    public let artist: String?
    public let title: String?
    public let value: String?
}

// MARK: - LyricsList (OpenSubsonic songLyrics extension)

public struct LyricsList: Decodable, Sendable, Equatable, Hashable {

    public let structuredLyrics: [StructuredLyrics]

    public init(structuredLyrics: [StructuredLyrics] = []) {
        self.structuredLyrics = structuredLyrics
    }

    private enum CodingKeys: String, CodingKey {
        case structuredLyrics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        structuredLyrics = try container.decodeIfPresent([StructuredLyrics].self, forKey: .structuredLyrics) ?? []
    }
}

// MARK: - LyricsKind (songLyrics v2)

public enum LyricsKind: String, Decodable, Sendable, Equatable, Hashable {
    case main
    case translation
    case pronunciation
}

// MARK: - LyricsAgent (songLyrics v2)

public struct LyricsAgent: Decodable, Sendable, Equatable, Hashable {
    public let id: String
    public let role: String
    public let voiceIndex: Int?
    public let displayRole: String?

    public init(id: String, role: String, voiceIndex: Int? = nil, displayRole: String? = nil) {
        self.id = id
        self.role = role
        self.voiceIndex = voiceIndex
        self.displayRole = displayRole
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, voiceIndex, displayRole
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        voiceIndex = try container.decodeIfPresent(Int.self, forKey: .voiceIndex)
        displayRole = try container.decodeIfPresent(String.self, forKey: .displayRole)
    }
}

// MARK: - LyricCue (songLyrics v2)

public struct LyricCue: Decodable, Sendable, Equatable, Hashable {
    public let start: Int
    public let end: Int?
    public let value: String
    public let byteStart: Int
    public let byteEnd: Int

    public init(start: Int, end: Int? = nil, value: String, byteStart: Int, byteEnd: Int) {
        self.start = start
        self.end = end
        self.value = value
        self.byteStart = byteStart
        self.byteEnd = byteEnd
    }
}

// MARK: - CueLine (songLyrics v2)

public struct CueLine: Decodable, Sendable, Equatable, Hashable {
    public let index: Int
    public let start: Int?
    public let end: Int?
    public let value: String
    public let agentId: String?
    public let cue: [LyricCue]

    public init(
        index: Int,
        start: Int? = nil,
        end: Int? = nil,
        value: String,
        agentId: String? = nil,
        cue: [LyricCue] = []
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.value = value
        self.agentId = agentId
        self.cue = cue
    }

    private enum CodingKeys: String, CodingKey {
        case index, start, end, value, agentId, cue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        start = try container.decodeIfPresent(Int.self, forKey: .start)
        end = try container.decodeIfPresent(Int.self, forKey: .end)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        cue = try container.decodeIfPresent([LyricCue].self, forKey: .cue) ?? []
    }
}

// MARK: - StructuredLyrics

public struct StructuredLyrics: Decodable, Sendable, Equatable, Hashable {

    public let lang: String?
    public let synced: Bool
    public let line: [Line]
    public let displayArtist: String?
    public let displayTitle: String?
    public let offset: Int
    public let kind: LyricsKind?
    public let agents: [LyricsAgent]
    public let cueLine: [CueLine]

    public init(
        lang: String? = nil,
        synced: Bool,
        line: [Line] = [],
        displayArtist: String? = nil,
        displayTitle: String? = nil,
        offset: Int = 0,
        kind: LyricsKind? = nil,
        agents: [LyricsAgent] = [],
        cueLine: [CueLine] = []
    ) {
        self.lang = lang
        self.synced = synced
        self.line = line
        self.displayArtist = displayArtist
        self.displayTitle = displayTitle
        self.offset = offset
        self.kind = kind
        self.agents = agents
        self.cueLine = cueLine
    }

    private enum CodingKeys: String, CodingKey {
        case lang, synced, line, displayArtist, displayTitle, offset
        case kind, agents, cueLine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        synced = try container.decodeIfPresent(Bool.self, forKey: .synced) ?? false
        line = try container.decodeIfPresent([Line].self, forKey: .line) ?? []
        displayArtist = try container.decodeIfPresent(String.self, forKey: .displayArtist)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        kind = try container.decodeIfPresent(LyricsKind.self, forKey: .kind)
        agents = try container.decodeIfPresent([LyricsAgent].self, forKey: .agents) ?? []
        cueLine = try container.decodeIfPresent([CueLine].self, forKey: .cueLine) ?? []
    }

    public var hasKaraokeCues: Bool {
        cueLine.contains { !$0.cue.isEmpty }
    }

    public var isPrimaryLayer: Bool {
        switch kind {
        case .none, .some(.main): return true
        case .some(.translation), .some(.pronunciation): return false
        }
    }
}

// MARK: - Line

public struct Line: Decodable, Sendable, Equatable, Hashable {
    public let value: String
    public let start: Int?

    public init(value: String, start: Int? = nil) {
        self.value = value
        self.start = start
    }
}

public typealias LyricsLine = Line
