// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

/// Fetches synced (preferred) or plain lyrics from [LRCLIB](https://lrclib.net).
nonisolated struct LRCLIBClient: ExternalLyricsProviding {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://lrclib.net")!) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchLyrics(match: LyricsMatchInfo) async throws -> LyricsList {
        guard match.canQueryExternal else { throw LyricsError.notFound }

        if let record = try await fetchExact(match: match) {
            return try list(from: record, match: match)
        }

        if let record = try await searchBest(match: match) {
            return try list(from: record, match: match)
        }

        throw LyricsError.notFound
    }

    // MARK: - API

    private func fetchExact(match: LyricsMatchInfo) async throws -> LRCLIBRecord? {
        guard match.durationSeconds > 0 else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: match.title),
            URLQueryItem(name: "artist_name", value: match.artist ?? ""),
            URLQueryItem(name: "album_name", value: match.album ?? match.title),
            URLQueryItem(name: "duration", value: String(match.durationSeconds)),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await data(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else {
                throw LyricsError.networkError(underlying: "LRCLIB HTTP \(http.statusCode)")
            }
            return try JSONDecoder().decode(LRCLIBRecord.self, from: data)
        } catch let error as LyricsError {
            throw error
        } catch is DecodingError {
            return nil
        } catch {
            throw LyricsError.networkError(underlying: error.localizedDescription)
        }
    }

    private func searchBest(match: LyricsMatchInfo) async throws -> LRCLIBRecord? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: match.title),
            URLQueryItem(name: "artist_name", value: match.artist ?? ""),
        ]
        if let album = match.album, !album.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = components.url else { return nil }

        let (data, response) = try await data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LyricsError.networkError(underlying: "LRCLIB search failed")
        }
        let results = (try? JSONDecoder().decode([LRCLIBRecord].self, from: data)) ?? []
        return pickBest(from: results, match: match)
    }

    private func pickBest(from results: [LRCLIBRecord], match: LyricsMatchInfo) -> LRCLIBRecord? {
        guard !results.isEmpty else { return nil }

        func durationScore(_ record: LRCLIBRecord) -> Int {
            guard match.durationSeconds > 0, let duration = record.duration else { return 50 }
            return abs(Int(duration.rounded()) - match.durationSeconds)
        }

        let ranked = results.sorted { a, b in
            let aSynced = a.hasSynced
            let bSynced = b.hasSynced
            if aSynced != bSynced { return aSynced && !bSynced }
            let aDur = durationScore(a)
            let bDur = durationScore(b)
            if aDur != bDur { return aDur < bDur }
            return (a.syncedLyrics?.count ?? 0) > (b.syncedLyrics?.count ?? 0)
        }

        let best = ranked.first
        // Prefer a duration match within ±3s when we know the track length.
        if match.durationSeconds > 0,
           let best,
           let duration = best.duration,
           abs(Int(duration.rounded()) - match.durationSeconds) > 3 {
            return ranked.first(where: {
                guard let d = $0.duration else { return false }
                return abs(Int(d.rounded()) - match.durationSeconds) <= 3
            }) ?? best
        }
        return best
    }

    private func list(from record: LRCLIBRecord, match: LyricsMatchInfo) throws -> LyricsList {
        if record.instrumental == true {
            throw LyricsError.notFound
        }

        if let synced = record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !synced.isEmpty {
            // ELRC-aware parsing: lines with explicit `<mm:ss.xx>` word stamps
            // produce karaoke `cueLine` cues (word-level). Plain LRC stays line-only
            // — NO interpolation is ever performed for missing word stamps.
            let parsed = LRCParser.parseEnhanced(synced)
            if !parsed.lines.isEmpty {
                return LyricsList(structuredLyrics: [
                    StructuredLyrics(
                        lang: "und",
                        synced: true,
                        line: parsed.lines,
                        displayArtist: record.artistName ?? match.artist,
                        displayTitle: record.trackName ?? match.title,
                        offset: 0,
                        cueLine: parsed.cueLines
                    )
                ])
            }
        }

        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            let lines = LRCParser.parsePlain(plain)
            guard !lines.isEmpty else { throw LyricsError.notFound }
            return LyricsList(structuredLyrics: [
                StructuredLyrics(
                    lang: "und",
                    synced: false,
                    line: lines,
                    displayArtist: record.artistName ?? match.artist,
                    displayTitle: record.trackName ?? match.title,
                    offset: 0
                )
            ])
        }

        throw LyricsError.notFound
    }

    private func data(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(
            "Cassette (https://github.com/MathieuDubart/Cassette)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        Logger.lyrics.debug("LRCLIB GET \(url.absoluteString, privacy: .public)")
        return try await session.data(for: request)
    }
}

// MARK: - DTOs

nonisolated private struct LRCLIBRecord: Decodable, Sendable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool {
        !(syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
