// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Builds a canonical ``LyricDocument`` from TTML (preferred), karaoke JSON, LRC, or plain text.
enum LyricDocumentBuilder {
    /// Priority: raw TTML → karaoke cueLines → line-synced → plain.
    nonisolated static func build(
        preferringTTML ttmlData: Data? = nil,
        structured: StructuredLyrics? = nil
    ) -> LyricDocument? {
        if let ttmlData, let document = try? AppleLyricTTMLParser.parse(data: ttmlData) {
            return document
        }
        guard let structured else { return nil }
        return fromStructured(structured)
    }

    nonisolated static func fromStructured(_ structured: StructuredLyrics) -> LyricDocument {
        if !structured.cueLine.isEmpty {
            return StructuredLyricsAdapter.document(from: structured)
        }
        if structured.synced, structured.line.contains(where: { $0.start != nil }) {
            return LineSyncedAdapter.document(from: structured)
        }
        return PlainTextAdapter.document(from: structured)
    }
}

// MARK: - Karaoke JSON (OpenSubsonic songLyrics)

nonisolated enum StructuredLyricsAdapter {
    static func document(from structured: StructuredLyrics) -> LyricDocument {
        let agentsById = Dictionary(uniqueKeysWithValues: structured.agents.map { agent in
            (
                agent.id,
                LyricAgent(
                    id: agent.id,
                    name: nil,
                    type: nil,
                    role: agent.role
                )
            )
        })

        var lines: [LyricLine] = []
        var order = 0

        for (index, line) in structured.line.enumerated() {
            let cueLines = structured.cueLine.filter { $0.index == index && !$0.cue.isEmpty }
            if cueLines.isEmpty {
                let begin = line.start.map(LyricTime.seconds(fromMilliseconds:))
                let text = line.value
                let words: [LyricWord]
                if let begin {
                    words = [
                        LyricWord(
                            text: text,
                            begin: begin,
                            end: begin,
                            role: .main
                        ),
                    ]
                } else {
                    words = []
                }
                lines.append(
                    LyricLine(
                        begin: begin,
                        end: begin,
                        key: nil,
                        agentId: nil,
                        words: words.isEmpty
                            ? [LyricWord(text: text, begin: 0, end: 0, role: .main)]
                            : words,
                        documentOrder: order,
                        sourceLineIndex: index
                    )
                )
                order += 1
                continue
            }

            // Merge same-index main + background cueLines into one TTML-like line.
            let mainCues = cueLines.filter { !isBackgroundAgent($0.agentId, agents: agentsById) }
            let bgCues = cueLines.filter { isBackgroundAgent($0.agentId, agents: agentsById) }

            if mainCues.count <= 1 {
                let lead = mainCues.first ?? cueLines.first!
                var cueWords = makeWords(from: lead, role: roleForAgent(lead.agentId, agents: agentsById))
                for bg in (mainCues.isEmpty ? Array(bgCues.dropFirst()) : bgCues) {
                    cueWords.append(contentsOf: makeWords(from: bg, role: .background))
                }
                cueWords.sort { $0.begin < $1.begin }
                let begin = lead.start.map(LyricTime.seconds(fromMilliseconds:))
                    ?? cueWords.first?.begin
                    ?? line.start.map(LyricTime.seconds(fromMilliseconds:))
                let end = lead.end.map(LyricTime.seconds(fromMilliseconds:))
                    ?? cueWords.map(\.end).max()
                    ?? begin
                lines.append(
                    LyricLine(
                        begin: begin,
                        end: end,
                        key: nil,
                        agentId: lead.agentId,
                        words: cueWords,
                        documentOrder: order,
                        sourceLineIndex: index
                    )
                )
                order += 1

                // Extra main agents on the same index (rare) → separate duet lines.
                for extra in mainCues.dropFirst() {
                    let extraWords = makeWords(from: extra, role: .main)
                    lines.append(
                        LyricLine(
                            begin: extra.start.map(LyricTime.seconds(fromMilliseconds:))
                                ?? extraWords.first?.begin,
                            end: extra.end.map(LyricTime.seconds(fromMilliseconds:))
                                ?? extraWords.map(\.end).max(),
                            key: nil,
                            agentId: extra.agentId,
                            words: extraWords,
                            documentOrder: order,
                            sourceLineIndex: index
                        )
                    )
                    order += 1
                }
            } else {
                // Multiple lead agents (duet overlap on one parent line): keep separate.
                for cue in cueLines {
                    let role = roleForAgent(cue.agentId, agents: agentsById)
                    let cueWords = makeWords(from: cue, role: role)
                    lines.append(
                        LyricLine(
                            begin: cue.start.map(LyricTime.seconds(fromMilliseconds:))
                                ?? cueWords.first?.begin,
                            end: cue.end.map(LyricTime.seconds(fromMilliseconds:))
                                ?? cueWords.map(\.end).max(),
                            key: nil,
                            agentId: cue.agentId,
                            words: cueWords,
                            documentOrder: order,
                            sourceLineIndex: index
                        )
                    )
                    order += 1
                }
            }
        }

        // Background-only cueLines whose parent index had no main still appear via merge above.
        // Orphan bg cueLines with unique indices are already handled when mainCues.isEmpty —
        // then lead = first cueLine (may be bg). Ensure role stays background.
        lines = lines.map { line in
            guard line.words.allSatisfy(\.role.isBackground) == false,
                  let agentId = line.agentId,
                  isBackgroundAgent(agentId, agents: agentsById),
                  line.mainWords.isEmpty else { return line }
            return line
        }

        lines = lines.map { line in
            guard let index = line.sourceLineIndex, structured.line.indices.contains(index) else { return line }
            return restoringSpacing(in: line, source: structured.line[index].value)
        }
        let timing: LyricTimingMode = lines.contains(where: { $0.words.count > 1 }) ? .word : .line
        return LyricDocument(
            language: structured.lang,
            timing: timing,
            duration: nil,
            leadingSilence: 0,
            lyricOffset: 0,
            agents: agentsById,
            songwriters: [],
            sections: [
                LyricSection(begin: nil, end: nil, songPart: nil, lines: lines),
            ],
            translationLanguage: nil,
            translations: [:]
        )
    }

    private static func makeWords(from cueLine: CueLine, role: LyricRole) -> [LyricWord] {
        cueLine.cue.map { cue in
            let begin = LyricTime.seconds(fromMilliseconds: cue.start)
            let end = cue.end.map(LyricTime.seconds(fromMilliseconds:)) ?? begin
            return LyricWord(text: cue.value, begin: begin, end: end, role: role)
        }
    }

    /// Cue boundaries are timing boundaries, not word boundaries. The full source line
    /// determines spaces when both representations contain exactly the same characters.
    static func restoringSpacing(in line: LyricLine, source: String) -> LyricLine {
        let main = line.mainWords
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        guard !main.isEmpty, compact(main.map(\.text).joined()) == compact(source) else { return line }
        let characters = Array(source)
        var cursor = 0
        var words: [LyricWord] = []
        for word in line.words {
            guard !word.role.isBackground else { words.append(word); continue }
            let start = cursor
            var remaining = compact(word.text).count
            while cursor < characters.count, remaining > 0 {
                if !characters[cursor].isWhitespace { remaining -= 1 }
                cursor += 1
            }
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            words.append(LyricWord(text: String(characters[start..<cursor]), begin: word.begin, end: word.end,
                                   role: word.role, agentId: word.agentId, ruby: word.ruby))
        }
        return LyricLine(begin: line.begin, end: line.end, key: line.key, agentId: line.agentId,
                         words: words, documentOrder: line.documentOrder, sourceLineIndex: line.sourceLineIndex,
                         preservesSourceSpacing: true, preservesSourceTiming: line.preservesSourceTiming)
    }

    private static func isBackgroundAgent(_ id: String?, agents: [String: LyricAgent]) -> Bool {
        guard let id, let agent = agents[id] else { return false }
        return LyricRole.map(agent.role).isBackground
            || (agent.role?.lowercased().contains("back") == true)
            || (agent.role?.lowercased().contains("chorus") == true)
            || (agent.role?.lowercased().contains("choir") == true)
            || id.contains("__nd_bg__")
    }

    private static func roleForAgent(_ id: String?, agents: [String: LyricAgent]) -> LyricRole {
        guard let id, let agent = agents[id] else { return .main }
        if isBackgroundAgent(id, agents: agents) { return .background }
        return LyricRole.map(agent.role)
    }
}

// MARK: - Line-synced (LRC-like)

nonisolated enum LineSyncedAdapter {
    static func document(from structured: StructuredLyrics) -> LyricDocument {
        var order = 0
        let lines: [LyricLine] = structured.line.map { line in
            let begin = line.start.map(LyricTime.seconds(fromMilliseconds:))
            let word: LyricWord
            if let begin {
                // End filled later by display builder lookahead; provisional = begin.
                word = LyricWord(text: line.value, begin: begin, end: begin, role: .main)
            } else {
                word = LyricWord(text: line.value, begin: 0, end: 0, role: .main)
            }
            let result = LyricLine(
                begin: begin,
                end: begin,
                key: nil,
                agentId: nil,
                words: [word],
                documentOrder: order,
                sourceLineIndex: order
            )
            order += 1
            return result
        }

        // Fill line ends from next line start.
        let filled: [LyricLine] = lines.enumerated().map { index, line in
            guard let begin = line.begin else { return line }
            let end: TimeInterval
            if let next = lines.dropFirst(index + 1).lazy.compactMap(\.begin).first(where: { $0 > begin }) {
                end = next
            } else {
                end = begin + 4
            }
            let words = line.words.map {
                LyricWord(text: $0.text, begin: begin, end: end, role: .main)
            }
            return LyricLine(
                begin: begin,
                end: end,
                key: line.key,
                agentId: line.agentId,
                words: words,
                documentOrder: line.documentOrder,
                sourceLineIndex: line.sourceLineIndex
            )
        }

        return LyricDocument(
            language: structured.lang,
            timing: .line,
            duration: nil,
            leadingSilence: 0,
            lyricOffset: 0,
            agents: [:],
            songwriters: [],
            sections: [LyricSection(begin: nil, end: nil, songPart: nil, lines: filled)],
            translationLanguage: nil,
            translations: [:]
        )
    }
}

// MARK: - Plain / unsynced

nonisolated enum PlainTextAdapter {
    static func document(from structured: StructuredLyrics) -> LyricDocument {
        var order = 0
        let lines = structured.line.map { line -> LyricLine in
            defer { order += 1 }
            return LyricLine(
                begin: nil,
                end: nil,
                key: nil,
                agentId: nil,
                words: [LyricWord(text: line.value, begin: 0, end: 0, role: .main)],
                documentOrder: order,
                sourceLineIndex: order
            )
        }
        return LyricDocument(
            language: structured.lang,
            timing: .none,
            duration: nil,
            leadingSilence: 0,
            lyricOffset: 0,
            agents: [:],
            songwriters: [],
            sections: [LyricSection(begin: nil, end: nil, songPart: nil, lines: lines)],
            translationLanguage: nil,
            translations: [:]
        )
    }
}
