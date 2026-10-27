// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI
import SwiftSonic

/// Horizontal placement for a vocal part (Apple Music–style speaker layout).
nonisolated enum LyricSpeakerSide: String, Equatable, Sendable {
    case leading
    case center
    case trailing

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

nonisolated enum LyricSingerType: String, Equatable, Sendable {
    case lead
    case backing
}

/// On-screen word with Apple Music TTML role (main vs x-bg).
nonisolated struct LyricDisplayWord: Equatable, Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
    let role: LyricRole
    var preservesSourceSpacing: Bool = false

    var isBackground: Bool { role.isBackground }
}

/// One on-screen lyric row. Main and background words share a row as separate layers.
nonisolated struct LyricDisplayRow: Equatable, Sendable {
    let sourceLineIndex: Int
    let text: String
    let startMs: Int?
    let endMs: Int?
    /// Legacy karaoke cues (main words only) for callers that still read `CueLine`.
    let cueLine: CueLine?
    let isSecondaryAgent: Bool
    let speakerSide: LyricSpeakerSide
    /// Timed words with roles — prefer this over parenthesis heuristics.
    let words: [LyricDisplayWord]
    let agentId: String?
    let preservesSourceTiming: Bool

    var singerType: LyricSingerType { isSecondaryAgent ? .backing : .lead }

    var mainWords: [LyricDisplayWord] { words.filter { !$0.isBackground } }
    var backgroundWords: [LyricDisplayWord] { words.filter(\.isBackground) }

    var streamKey: String {
        if let agentId, !agentId.isEmpty {
            return "agent:\(agentId)"
        }
        if isSecondaryAgent {
            return "side:\(speakerSide.rawValue):secondary"
        }
        return "side:\(speakerSide.rawValue):lead"
    }

    init(
        sourceLineIndex: Int,
        text: String,
        startMs: Int?,
        endMs: Int?,
        cueLine: CueLine?,
        isSecondaryAgent: Bool,
        speakerSide: LyricSpeakerSide,
        words: [LyricDisplayWord] = [],
        agentId: String? = nil,
        preservesSourceTiming: Bool = false
    ) {
        self.sourceLineIndex = sourceLineIndex
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.cueLine = cueLine
        self.isSecondaryAgent = isSecondaryAgent
        self.speakerSide = speakerSide
        self.words = words
        self.agentId = agentId ?? cueLine?.agentId
        self.preservesSourceTiming = preservesSourceTiming
    }
}

nonisolated enum LyricDisplayBuilder {
    /// OpenSubsonic / LRC / plain path — adapts to ``LyricDocument`` first.
    static func rows(from structured: StructuredLyrics) -> [LyricDisplayRow] {
        rows(from: LyricDocumentBuilder.fromStructured(structured))
    }

    /// Canonical document path (TTML or adapted). Preserves document order.
    static func rows(from document: LyricDocument) -> [LyricDisplayRow] {
        let lines = document.allLines
        let primaryAgentId = document.primaryAgentId
        /// Multi-speaker is true when either the document declares multiple agents,
        /// OR when lines carry two or more distinct `agentId` values (belt-and-suspenders
        /// in case the parser could not register an agent with only an xml:id).
        let distinctLineAgentIds = Set(lines.compactMap(\.agentId))
        let multiSpeaker = distinctLineAgentIds.count > 1
            || document.agents.count > 1

        var rows: [LyricDisplayRow] = lines.map { line in
            let words = line.words.map { word in
                LyricDisplayWord(
                    text: word.text,
                    startMs: LyricTime.milliseconds(fromSeconds: word.begin),
                    endMs: LyricTime.milliseconds(fromSeconds: word.end),
                    role: word.role,
                    preservesSourceSpacing: line.preservesSourceSpacing
                )
            }
            let isSecondary = line.isBackgroundOnly
            let side = speakerSide(
                agentId: line.agentId,
                agent: line.agentId.flatMap { document.agents[$0] },
                isSecondary: isSecondary,
                mainAgentId: primaryAgentId,
                multiSpeaker: multiSpeaker
            )
            let startMs = document.timing == .none ? nil : line.resolvedBegin.map(LyricTime.milliseconds(fromSeconds:))
            let endMs = document.timing == .none ? nil : line.resolvedEnd.map(LyricTime.milliseconds(fromSeconds:))
            let main = words.filter { !$0.isBackground }
            let cue = synthesizeCueLine(from: main, agentId: line.agentId, sourceIndex: line.sourceLineIndex ?? 0)
            return LyricDisplayRow(
                sourceLineIndex: line.sourceLineIndex ?? line.documentOrder,
                text: line.isBackgroundOnly
                    ? line.backgroundWords.map(\.text).joined(separator: line.preservesSourceSpacing ? "" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    : line.displayText,
                startMs: startMs,
                endMs: endMs,
                cueLine: cue,
                isSecondaryAgent: isSecondary,
                speakerSide: side,
                words: words,
                agentId: line.agentId,
                preservesSourceTiming: line.preservesSourceTiming
            )
        }

        rows = withClippedEnds(rows)
        return rows
    }

    /// A lead row must dim as soon as the next lead starts. TTML often ends a line
    /// after the next line has already begun; keeping both in `activeRows` made the
    /// previous line stay bright until its own end. Preserved backing-vocal timings
    /// remain untouched.
    private static func withClippedEnds(_ rows: [LyricDisplayRow]) -> [LyricDisplayRow] {
        rows.enumerated().map { index, row in
            guard let ownEnd = row.endMs,
                  let nextLead = nextLeadStartMs(after: index, in: rows),
                  let start = row.startMs,
                  nextLead > start,
                  nextLead < ownEnd else { return row }
            if row.isSecondaryAgent && row.preservesSourceTiming { return row }
            return LyricDisplayRow(
                sourceLineIndex: row.sourceLineIndex,
                text: row.text,
                startMs: row.startMs,
                endMs: nextLead,
                cueLine: row.cueLine,
                isSecondaryAgent: row.isSecondaryAgent,
                speakerSide: row.speakerSide,
                words: row.words,
                agentId: row.agentId,
                preservesSourceTiming: row.preservesSourceTiming
            )
        }
    }

    private static func synthesizeCueLine(
        from words: [LyricDisplayWord],
        agentId: String?,
        sourceIndex: Int
    ) -> CueLine? {
        guard !words.isEmpty else { return nil }
        var byte = 0
        let cues: [LyricCue] = words.map { word in
            let value = word.text
            let utf8 = value.utf8.count
            let cue = LyricCue(
                start: word.startMs,
                end: word.endMs,
                value: value,
                byteStart: byte,
                byteEnd: byte + max(utf8 - 1, 0)
            )
            byte += utf8
            return cue
        }
        return CueLine(
            index: sourceIndex,
            start: words.first?.startMs,
            end: words.last?.endMs,
            value: words.map(\.text).joined(),
            agentId: agentId,
            cue: cues
        )
    }

    static func withPrecomputedEnds(_ rows: [LyricDisplayRow]) -> [LyricDisplayRow] {
        // Ends already come from the document; keep API for tests.
        withClippedEnds(rows)
    }

    static func chronologicallyOrdered(_ rows: [LyricDisplayRow]) -> [LyricDisplayRow] {
        rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            let aStart = a.startMs ?? Int.max
            let bStart = b.startMs ?? Int.max
            if aStart != bStart { return aStart < bStart }
            if a.sourceLineIndex != b.sourceLineIndex {
                return a.sourceLineIndex < b.sourceLineIndex
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func nextLeadStartMs(after index: Int, in rows: [LyricDisplayRow]) -> Int? {
        guard index + 1 < rows.count else { return nil }
        for row in rows[(index + 1)...] {
            guard !row.isSecondaryAgent, let start = row.startMs else { continue }
            return start
        }
        return nil
    }

    /// Apple Music vocal placement from agent metadata.
    static func speakerSide(
        agentId: String?,
        agent: LyricAgent?,
        isSecondary: Bool,
        mainAgentId: String?,
        multiSpeaker: Bool
    ) -> LyricSpeakerSide {
        if agent?.type?.lowercased() == "group" { return .center }
        guard multiSpeaker else { return .leading }
        if isSecondary { return .leading }

        if let agent {
            let role = (agent.role ?? "").lowercased()
            switch role {
            case "group":
                return .center
            case "bg", "background", "chorus", "choir", "backing", "x-bg":
                return .leading
            case "featured", "featuring", "guest", "duet":
                return .trailing
            case "main", "voice", "":
                if let mainAgentId, agent.id != mainAgentId { return .trailing }
                return .leading
            default:
                if let mainAgentId, agent.id != mainAgentId { return .trailing }
                return .leading
            }
        }
        if let mainAgentId, let agentId, agentId != mainAgentId {
            return .trailing
        }
        return .leading
    }

    /// Legacy test / call-site helper using SwiftSonic ``LyricsAgent``.
    static func speakerSide(
        for agent: LyricsAgent?,
        mainAgentId: String?,
        cue: CueLine?,
        siblings: [CueLine],
        multiSpeaker: Bool
    ) -> LyricSpeakerSide {
        _ = siblings
        let mapped = agent.map {
            LyricAgent(id: $0.id, name: nil, type: nil, role: $0.role)
        }
        return speakerSide(
            agentId: cue?.agentId ?? agent?.id,
            agent: mapped,
            isSecondary: false,
            mainAgentId: mainAgentId,
            multiSpeaker: multiSpeaker
        )
    }

    /// Convenience for one-off lookups. Playback should retain a timeline across frames.
    static func activeRows(
        for adjustedMs: Int,
        in rows: [LyricDisplayRow],
        simultaneousThresholdMs: Int = 500
    ) -> (primary: Int?, indices: Set<Int>) {
        _ = simultaneousThresholdMs
        return LyricPlaybackTimeline(rows: rows).activeRows(for: adjustedMs)
    }

    static func vocalPartEndMs(
        _ row: LyricDisplayRow,
        at index: Int,
        in rows: [LyricDisplayRow]
    ) -> Int? {
        _ = index
        _ = rows
        if let endMs = row.endMs { return endMs }
        return row.words.map(\.endMs).max() ?? row.cueLine?.end
    }

    static func vocalPartEndMs(_ row: LyricDisplayRow) -> Int? {
        if let endMs = row.endMs { return endMs }
        return row.words.map(\.endMs).max() ?? row.cueLine?.end
    }
}
