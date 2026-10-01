// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

// SwiftSonic types are Decodable-only. These retroactive Encodable conformances let Cassette
// round-trip a LyricsList through JSONEncoder for SwiftData cache persistence.
// Auto-synthesis is blocked cross-module, so encode(to:) is implemented explicitly
// using the same key names as SwiftSonic's own CodingKeys.

extension Line: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey { case value, start }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(start, forKey: .start)
    }
}

extension LyricsKind: @retroactive Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension LyricsAgent: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey { case id, role, voiceIndex, displayRole }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(voiceIndex, forKey: .voiceIndex)
        try c.encodeIfPresent(displayRole, forKey: .displayRole)
    }
}

extension LyricCue: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey { case start, end, value, byteStart, byteEnd }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encode(value, forKey: .value)
        try c.encode(byteStart, forKey: .byteStart)
        try c.encode(byteEnd, forKey: .byteEnd)
    }
}

extension CueLine: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey { case index, start, end, value, agentId, cue }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encodeIfPresent(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(agentId, forKey: .agentId)
        try c.encode(cue, forKey: .cue)
    }
}

extension StructuredLyrics: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey {
        case lang, synced, line, displayArtist, displayTitle, offset
        case kind, agents, cueLine
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lang, forKey: .lang)
        try c.encode(synced, forKey: .synced)
        try c.encode(line, forKey: .line)
        try c.encodeIfPresent(displayArtist, forKey: .displayArtist)
        try c.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try c.encode(offset, forKey: .offset)
        try c.encodeIfPresent(kind, forKey: .kind)
        if !agents.isEmpty {
            try c.encode(agents, forKey: .agents)
        }
        if !cueLine.isEmpty {
            try c.encode(cueLine, forKey: .cueLine)
        }
    }
}

extension LyricsList: @retroactive Encodable {
    private enum CodingKeys: String, CodingKey { case structuredLyrics }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(structuredLyrics, forKey: .structuredLyrics)
    }
}
