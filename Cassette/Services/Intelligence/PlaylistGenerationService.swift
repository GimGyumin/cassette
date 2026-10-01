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

/// Generates playlist drafts from the user's library (scan → pick), using Apple Intelligence when available.
@MainActor
enum PlaylistGenerationService {
    struct GeneratedTrack: Sendable, Equatable {
        let id: String?
        let title: String
        let artist: String?
    }

    struct Result: Sendable {
        let name: String
        let description: String?
        /// `PlaylistGradientShape.rawValue` when the model picks a cover form.
        let coverShape: String?
        let tracks: [GeneratedTrack]
        /// Songs already resolved from the scanned library pool (preferred over re-search).
        let songs: [Song]

        init(
            name: String,
            description: String?,
            coverShape: String?,
            tracks: [GeneratedTrack],
            songs: [Song] = []
        ) {
            self.name = name
            self.description = description
            self.coverShape = coverShape
            self.tracks = tracks
            self.songs = songs
        }
    }

    enum Progress: Sendable, Equatable {
        case preparing
        case scanning
        case drafting(version: Int, total: Int)
        case matching(version: Int, total: Int)
        case comparing
        case resolving
        case finished
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return CassetteFoundationModel.isAvailable
        }
        #endif
        return false
    }

    static let coverShapeChoices: [String] = PlaylistGradientShape.allCases.map(\.rawValue)
    private static let scanPoolSize = 160
    private static let catalogPromptLimit = 100

    /// Scan the library, then draft a playlist by picking from that pool.
    static func generate(
        prompt: String,
        libraryService: (any LibraryServiceProtocol)? = nil,
        onProgress: (@MainActor (Progress) -> Void)? = nil
    ) async throws -> Result {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CassetteError.notImplemented
        }

        onProgress?(.preparing)

        var pool: [Song] = []
        if let libraryService {
            onProgress?(.scanning)
            pool = await scanLibrary(libraryService)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), CassetteFoundationModel.isAvailable, !pool.isEmpty {
            do {
                return try await generateMultiVersion(
                    prompt: trimmed,
                    pool: pool,
                    onProgress: onProgress
                )
            } catch {
                Logger.playlist.warning(
                    "FoundationModels playlist gen failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        #endif

        onProgress?(.drafting(version: 1, total: 1))
        let fallback = heuristic(prompt: trimmed, pool: pool)
        onProgress?(.finished)
        return fallback
    }

    /// Resolve generated picks to library songs (prefers songs already attached from the scan).
    static func resolveTracks(
        from result: Result,
        libraryService: any LibraryServiceProtocol,
        onProgress: (@MainActor (Progress) -> Void)? = nil
    ) async -> [Song] {
        onProgress?(.resolving)

        // Catalog picks already carry Song instances — skip fragile re-search.
        if !result.songs.isEmpty {
            var seen = Set<String>()
            let unique = result.songs.filter { seen.insert($0.id).inserted }
            onProgress?(.finished)
            return Array(unique.prefix(40))
        }

        var songs: [Song] = []
        var seen = Set<String>()

        for track in result.tracks {
            let query = [track.title, track.artist].compactMap { $0 }.joined(separator: " ")
            guard !query.isEmpty else { continue }
            guard let search = try? await libraryService.search(query),
                  let candidates = search.song, !candidates.isEmpty else { continue }
            let hit: Song
            if let id = track.id, let exact = candidates.first(where: { $0.id == id }) {
                hit = exact
            } else {
                hit = candidates[0]
            }
            guard !seen.contains(hit.id) else { continue }
            seen.insert(hit.id)
            songs.append(hit)
            if songs.count >= 40 { break }
        }
        onProgress?(.finished)
        return songs
    }

    /// Resolve and create a playlist on the server.
    static func createPlaylist(
        from result: Result,
        libraryService: any LibraryServiceProtocol,
        playlistService: any PlaylistServiceProtocol,
        onProgress: (@MainActor (Progress) -> Void)? = nil
    ) async throws -> PlaylistWithSongs {
        let songs = await resolveTracks(from: result, libraryService: libraryService, onProgress: onProgress)
        guard !songs.isEmpty else {
            throw CassetteError.smartShuffleEmpty
        }
        let description = result.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await playlistService.createPlaylist(
            name: result.name,
            description: (description?.isEmpty == false) ? description : nil
        )
        try await playlistService.addTracks(playlistId: created.id, songs: songs)
        onProgress?(.finished)
        return try await playlistService.getPlaylist(id: created.id)
    }

    // MARK: - Library scan

    private static func scanLibrary(_ libraryService: any LibraryServiceProtocol) async -> [Song] {
        do {
            let songs = try await libraryService.randomSongs(size: scanPoolSize)
            // Deduplicate by id while keeping order.
            var seen = Set<String>()
            return songs.filter { seen.insert($0.id).inserted }
        } catch {
            Logger.playlist.warning(
                "Library scan for AI playlist failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func generateMultiVersion(
        prompt: String,
        pool: [Song],
        onProgress: (@MainActor (Progress) -> Void)?
    ) async throws -> Result {
        let angles = [
            "Focus on emotional flow and natural transitions between songs.",
            "Prefer well-known, crowd-pleasing tracks that fit the request.",
            "Include deeper cuts and variety while staying on theme.",
        ]
        let total = angles.count
        let catalog = Array(pool.prefix(catalogPromptLimit))
        var drafts: [Result] = []

        for (index, angle) in angles.enumerated() {
            onProgress?(.drafting(version: index + 1, total: total))
            if let draft = try? await generateFromCatalog(
                prompt: prompt,
                angle: angle,
                catalog: catalog
            ) {
                drafts.append(draft)
            }
        }

        guard !drafts.isEmpty else {
            return heuristic(prompt: prompt, pool: pool)
        }

        onProgress?(.comparing)
        // Prefer drafts that kept more in-catalog picks (all should), then diversity of artists.
        let scored = drafts.map { draft -> (Result, Double) in
            let artists = Set(draft.tracks.compactMap { $0.artist?.lowercased() })
            let score = Double(draft.tracks.count) + Double(artists.count) * 0.3
            return (draft, score)
        }
        .sorted { $0.1 > $1.1 }

        let winner = scored[0].0
        let blended = blend(winner: winner, runnersUp: scored.dropFirst().map(\.0), pool: pool)
        onProgress?(.finished)
        return blended
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func generateFromCatalog(
        prompt: String,
        angle: String,
        catalog: [Song]
    ) async throws -> Result {
        let session = CassetteFoundationModel.makeSession(
            instructions: """
            You build playlists ONLY from a numbered catalog of songs the user already owns.
            Never invent song titles. Reply with compact JSON only.
            """
        )
        let covers = coverShapeChoices.joined(separator: "|")
        let language = AppLanguage.current
        let languageNote = language == .korean
            ? "Use Korean for name and description."
            : "Use English for name and description."

        let catalogLines = catalog.enumerated().map { index, song in
            let artist = song.artist ?? "?"
            let album = song.album ?? ""
            let albumPart = album.isEmpty ? "" : " | \(album)"
            return "\(index + 1). \(artist) — \(song.title)\(albumPart)"
        }.joined(separator: "\n")

        let instructions = """
        User request: \(prompt)
        Angle: \(angle)
        \(languageNote)

        CATALOG (pick ONLY from these numbers):
        \(catalogLines)

        Reply with ONLY compact JSON (no markdown):
        {"name":"Playlist Name","description":"1-2 sentence blurb","cover":"verticalFade","picks":[3,7,12]}
        Rules:
        - cover must be one of: \(covers)
        - picks: 12-18 unique catalog numbers that best match the request
        - Do not mention songs outside the catalog
        """
        let response = try await session.respond(
            to: instructions,
            options: CassetteFoundationModel.groundedOptions
        )
        if let parsed = parseCatalogJSON(response.content, catalog: catalog) {
            return parsed
        }
        throw CassetteError.notImplemented
    }
    #endif

    private static func blend(winner: Result, runnersUp: [Result], pool: [Song]) -> Result {
        var seen = Set(winner.tracks.map { key(for: $0) })
        var tracks = winner.tracks
        var songs = winner.songs
        let songsById = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })

        for draft in runnersUp {
            for track in draft.tracks {
                let k = key(for: track)
                guard !seen.contains(k) else { continue }
                seen.insert(k)
                tracks.append(track)
                if let id = track.id, let song = songsById[id] {
                    songs.append(song)
                }
                if tracks.count >= 22 { break }
            }
            if tracks.count >= 22 { break }
        }
        // If still short, pad from pool by prompt-irrelevant order (already scanned).
        if tracks.count < 12 {
            for song in pool {
                let track = GeneratedTrack(id: song.id, title: song.title, artist: song.artist)
                let k = key(for: track)
                guard !seen.contains(k) else { continue }
                seen.insert(k)
                tracks.append(track)
                songs.append(song)
                if tracks.count >= 16 { break }
            }
        }
        let limitedTracks = Array(tracks.prefix(20))
        var limitedSeen = Set<String>()
        let limitedSongs = songs.filter { limitedSeen.insert($0.id).inserted }.prefix(20)
        return Result(
            name: winner.name,
            description: winner.description,
            coverShape: winner.coverShape,
            tracks: limitedTracks,
            songs: Array(limitedSongs)
        )
    }

    private static func key(for track: GeneratedTrack) -> String {
        if let id = track.id, !id.isEmpty { return "id:\(id)" }
        return "\(track.title.lowercased())|\((track.artist ?? "").lowercased())"
    }

    private static func parseCatalogJSON(_ text: String, catalog: [Song]) -> Result? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }

        let description = (obj["description"] as? String)
            ?? (obj["comment"] as? String)
        let coverRaw = (obj["cover"] as? String)
            ?? (obj["coverShape"] as? String)
        let coverShape = coverRaw.flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if PlaylistGradientShape(rawValue: trimmed) != nil { return trimmed }
            return PlaylistGradientShape.allCases.first {
                $0.displayName.lowercased() == trimmed.lowercased()
                    || $0.rawValue.lowercased() == trimmed.lowercased()
            }?.rawValue
        }

        var picks: [Int] = []
        if let arr = obj["picks"] as? [Int] {
            picks = arr
        } else if let arr = obj["picks"] as? [NSNumber] {
            picks = arr.map(\.intValue)
        } else if let tracks = obj["tracks"] as? [[String: Any]] {
            // Legacy shape — try title match against catalog.
            let mapped: [GeneratedTrack] = tracks.compactMap { row in
                guard let title = row["title"] as? String, !title.isEmpty else { return nil }
                let artist = row["artist"] as? String
                if let song = catalog.first(where: {
                    $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                        && (artist == nil || ($0.artist ?? "").localizedCaseInsensitiveCompare(artist!) == .orderedSame)
                }) {
                    return GeneratedTrack(id: song.id, title: song.title, artist: song.artist)
                }
                return GeneratedTrack(id: nil, title: title, artist: artist)
            }
            guard !mapped.isEmpty else { return nil }
            let songs = mapped.compactMap { track -> Song? in
                guard let id = track.id else { return nil }
                return catalog.first(where: { $0.id == id })
            }
            return Result(name: name, description: description, coverShape: coverShape, tracks: mapped, songs: songs)
        }

        var seen = Set<Int>()
        var mapped: [GeneratedTrack] = []
        var songs: [Song] = []
        for pick in picks {
            let index = pick - 1
            guard catalog.indices.contains(index), seen.insert(index).inserted else { continue }
            let song = catalog[index]
            mapped.append(GeneratedTrack(id: song.id, title: song.title, artist: song.artist))
            songs.append(song)
        }
        guard !mapped.isEmpty else { return nil }
        return Result(name: name, description: description, coverShape: coverShape, tracks: mapped, songs: songs)
    }

    private static func heuristic(prompt: String, pool: [Song]) -> Result {
        let name = prompt.count > 40 ? String(prompt.prefix(40)) + "…" : prompt
        let tokens = prompt
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count > 2 }

        var scored: [(Song, Int)] = pool.map { song in
            let hay = "\(song.title) \(song.artist ?? "") \(song.album ?? "") \(song.genre ?? "")".lowercased()
            let hits = tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            return (song, hits)
        }
        scored.sort { $0.1 > $1.1 }

        let chosen: [Song]
        if let best = scored.first?.1, best > 0 {
            chosen = scored.filter { $0.1 > 0 }.prefix(18).map(\.0)
        } else {
            chosen = Array(pool.prefix(16))
        }

        let tracks = chosen.map { GeneratedTrack(id: $0.id, title: $0.title, artist: $0.artist) }
        return Result(
            name: name.isEmpty ? "Generated Playlist" : name,
            description: prompt,
            coverShape: PlaylistGradientShape.verticalFade.rawValue,
            tracks: tracks,
            songs: chosen
        )
    }
}
