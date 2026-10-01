// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Song Info AI: search Wikipedia / MusicBrainz about the track, load lyrics, then summarize.
@MainActor
enum SongInsightService {
    enum Progress: Sendable, Equatable {
        case preparing
        case searching
        case loadingLyrics
        case summarizing
        case finished
    }

    struct Result: Sendable {
        let text: String
        let lyricsLines: [String]
        let hadResearch: Bool
        let hadLyrics: Bool
    }

    static func generate(
        song: DisplayableSong,
        seedLyrics: [String],
        lyricsService: LyricsService?,
        serverId: UUID?,
        onProgress: (@MainActor (Progress) -> Void)? = nil
    ) async -> Result? {
        onProgress?(.preparing)

        onProgress?(.searching)
        let research = await ExternalDescriptionService.shared.researchSong(
            title: song.title,
            artistName: song.artist,
            albumName: song.albumName
        )

        onProgress?(.loadingLyrics)
        let lyrics = await resolveLyrics(
            song: song,
            seed: seedLyrics,
            lyricsService: lyricsService,
            serverId: serverId
        )

        onProgress?(.summarizing)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), CassetteFoundationModel.isAvailable {
            if let text = await summarizeWithFoundationModels(
                song: song,
                research: research,
                lyrics: lyrics
            ) {
                // Guard against the model falsely claiming lyrics were missing when we have them.
                let repaired = repairFalseMissingLyricsClaim(text, hadLyrics: !lyrics.isEmpty)
                onProgress?(.finished)
                return Result(
                    text: repaired,
                    lyricsLines: lyrics,
                    hadResearch: !research.isEmpty,
                    hadLyrics: !lyrics.isEmpty
                )
            }
        }
        #endif

        let fallback = fallbackInsight(song: song, research: research, lyrics: lyrics)
        guard !fallback.isEmpty else { return nil }
        onProgress?(.finished)
        return Result(
            text: fallback,
            lyricsLines: lyrics,
            hadResearch: !research.isEmpty,
            hadLyrics: !lyrics.isEmpty
        )
    }

    // MARK: - Lyrics

    private static func resolveLyrics(
        song: DisplayableSong,
        seed: [String],
        lyricsService: LyricsService?,
        serverId: UUID?
    ) async -> [String] {
        let seeded = seed
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !seeded.isEmpty { return Array(seeded.prefix(60)) }

        guard let lyricsService, let serverId else { return [] }
        do {
            let list = try await lyricsService.fetchLyrics(
                forSongId: song.id,
                serverId: serverId,
                match: LyricsMatchInfo(song: song)
            )
            // Same language pick as the player — never flatten every lang (empty/alt sets
            // can drown out the real lyrics and make the model claim none were loaded).
            let best = lyricsService.selectBestLanguage(from: list)
                ?? list.structuredLyrics.first(where: { !$0.line.isEmpty })
                ?? list.structuredLyrics.first
            let lines = (best?.line ?? [])
                .map(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(lines.prefix(60))
        } catch {
            Logger.lyrics.debug(
                "Song insight lyrics fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Summarize

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func summarizeWithFoundationModels(
        song: DisplayableSong,
        research: ExternalDescriptionService.SongResearchContext,
        lyrics: [String]
    ) async -> String? {
        let language = AppLanguage.current
        let session = CassetteFoundationModel.makeSession(
            instructions: language.songResearchSessionInstructions
        )

        var meta: [String] = ["Title: \(song.title)"]
        if let artist = song.artist, !artist.isEmpty { meta.append("Artist: \(artist)") }
        if let album = song.albumName, !album.isEmpty { meta.append("Album: \(album)") }
        if let genre = song.genre, !genre.isEmpty { meta.append("Genre: \(genre)") }
        if let composer = song.displayComposer, !composer.isEmpty { meta.append("Composer: \(composer)") }

        let researchBlock = research.isEmpty
            ? (language == .korean
               ? "RESEARCH: (검색 결과 없음 — 태그·가사만 사용)"
               : "RESEARCH: (none found — use tags and lyrics only)")
            : research.sourceBlock

        let hasLyrics = !lyrics.isEmpty
        let lyricsBlock: String
        if hasLyrics {
            lyricsBlock = """
            LYRICS (PRESENT — you MUST write lyric commentary; NEVER say lyrics are missing/unavailable):
            \(lyrics.joined(separator: "\n"))
            """
        } else {
            lyricsBlock = language == .korean
                ? "LYRICS: (없음 — 둘째 단락에만 「가사를 불러오지 못해 가사 해설은 생략합니다.」)"
                : "LYRICS: (none — second paragraph must say lyrics could not be loaded)"
        }

        // Two-step when lyrics exist: research summary first, then lyric reading — keeps
        // the lyrics block from being truncated/ignored in a single long prompt.
        if hasLyrics {
            do {
                let aboutPrompt = """
                \(language == .korean
                    ? "아래 RESEARCH와 태그만으로 곡·앨범·아티스트 배경을 한국어 3~5문장으로 요약하세요. 가사 언급 금지. JSON·메타 인사 금지."
                    : "Using RESEARCH and tags only, summarize song/album/artist background in 3–5 English sentences. Do not mention lyrics. No JSON or greetings.")

                \(meta.joined(separator: "\n"))

                \(researchBlock)
                """
                let aboutResponse = try await session.respond(
                    to: aboutPrompt,
                    options: CassetteFoundationModel.groundedOptions
                )
                let about = sanitize(aboutResponse.content)

                let lyricsPrompt = """
                \(language.lyricsSummaryPromptPrefix)

                \(meta.joined(separator: "\n"))

                LYRICS:
                \(lyrics.joined(separator: "\n"))
                """
                let lyricsResponse = try await session.respond(
                    to: lyricsPrompt,
                    options: CassetteFoundationModel.groundedOptions
                )
                let lyricText = sanitize(lyricsResponse.content)

                let combined = [about, lyricText]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n---\n\n")
                return combined.isEmpty ? nil : combined
            } catch {
                Logger.playlist.warning(
                    "Song insight two-step summarize failed: \(error.localizedDescription, privacy: .public)"
                )
                // Fall through to single-shot prompt.
            }
        }

        let prompt = """
        \(language.songResearchPromptPrefix)

        \(meta.joined(separator: "\n"))

        \(researchBlock)

        \(lyricsBlock)
        """

        do {
            let response = try await session.respond(
                to: prompt,
                options: CassetteFoundationModel.groundedOptions
            )
            let cleaned = sanitize(response.content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            Logger.playlist.warning(
                "Song insight summarize failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
    #endif

    /// If the model still claims lyrics are missing while we supplied them, strip that claim.
    private static func repairFalseMissingLyricsClaim(_ text: String, hadLyrics: Bool) -> String {
        guard hadLyrics else { return text }
        let exactPhrases = [
            "가사를 불러오지 못해 가사 해설은 생략합니다.",
            "가사가 없어 가사 해설은 생략합니다.",
            "Lyrics could not be loaded, so lyric commentary is skipped.",
            "No lyrics are loaded, so lyric commentary is skipped.",
        ]
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return exactPhrases.contains(where: { trimmed == $0 || trimmed.contains($0) })
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackInsight(
        song: DisplayableSong,
        research: ExternalDescriptionService.SongResearchContext,
        lyrics: [String]
    ) -> String {
        var parts: [String] = []
        if let song = research.songExtract, !song.isEmpty {
            parts.append(song)
        } else if let album = research.albumExtract, !album.isEmpty {
            parts.append(album)
        } else if let artist = research.artistExtract, !artist.isEmpty {
            parts.append(artist)
        } else {
            var tagLine = song.title
            if let artist = song.artist { tagLine += " — \(artist)" }
            if let album = song.albumName { tagLine += " · \(album)" }
            parts.append(tagLine)
        }

        if !lyrics.isEmpty {
            let language = AppLanguage.current
            let note = language == .korean
                ? "가사가 로드되어 있습니다. Apple Intelligence를 사용할 수 없을 때는 가사 해설을 생성하지 않습니다."
                : "Lyrics are available. Lyric commentary requires Apple Intelligence on this device."
            parts.append(note)
        }

        return parts.joined(separator: "\n\n")
    }

    private static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip common meta preambles.
        let metaPrefixes = [
            "i can answer", "of course", "다음과 같이", "물론입니다", "정보를 수집",
        ]
        let lines = text.components(separatedBy: "\n")
        var start = 0
        while start < lines.count {
            let lower = lines[start].trimmingCharacters(in: .whitespaces).lowercased()
            if lower.isEmpty || metaPrefixes.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
                start += 1
                continue
            }
            break
        }
        return lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
