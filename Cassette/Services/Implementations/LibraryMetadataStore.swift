// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

/// Deterministic ranking shared by Siri's persistent cache and fresh server results.
/// Navidrome's `search3` order is relevance-oriented but does not understand a spoken
/// album constraint, so it can put a remix or a same-titled single ahead of the
/// requested album track. Re-ranking both sources together keeps those variants from
/// winning unless the person actually asked for them.
nonisolated enum SiriSongSearchRanker {
    private static let titleVariantTokens: Set<String> = [
        "acoustic", "demo", "edit", "extended", "instrumental", "karaoke",
        "live", "mix", "mono", "radio", "remaster", "remastered", "remix",
        "reprise", "slowed", "sped", "stereo", "version",
    ]

    private static let releaseVariantTokens: Set<String> = [
        "single", "ep", "compilation", "soundtrack",
    ]

    static func score(_ song: DisplayableSong, query: String) -> Int {
        let queryTokens = HangulRomanization.searchTokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let titleTokens = HangulRomanization.searchTokens(song.title)
        let artistTokens = HangulRomanization.searchTokens(song.artist ?? "")
        let albumTokens = HangulRomanization.searchTokens(song.albumName ?? "")
        let querySet = Set(queryTokens)

        let unrequestedTitleVariants = Set(titleTokens)
            .intersection(titleVariantTokens)
            .subtracting(querySet)
        let canonicalTitle = titleTokens.filter { !titleVariantTokens.contains($0) }

        var score = 0
        if titleTokens == queryTokens {
            score += 700
        } else if contains(canonicalTitle, in: queryTokens) {
            score += 360
        }

        score += fieldScore(tokens: titleTokens, query: queryTokens, exact: 80, partial: 28)
        score += fieldScore(tokens: artistTokens, query: queryTokens, exact: 35, partial: 12)
        score += fieldScore(tokens: albumTokens, query: queryTokens, exact: 10, partial: 4)

        // A complete album/artist phrase in the request is a strong constraint. This
        // is what makes "Beat It from Thriller" prefer the Thriller album recording.
        if !albumTokens.isEmpty, contains(albumTokens, in: queryTokens) {
            score += 260
        }
        if !artistTokens.isEmpty, contains(artistTokens, in: queryTokens) {
            score += 180
        }

        score -= unrequestedTitleVariants.count * 220

        let unrequestedReleaseVariants = Set(albumTokens)
            .intersection(releaseVariantTokens)
            .subtracting(querySet)
        score -= unrequestedReleaseVariants.count * 100
        return max(score, 0)
    }

    private static func fieldScore(tokens: [String], query: [String], exact: Int, partial: Int) -> Int {
        var score = 0
        for queryToken in query {
            if tokens.contains(queryToken) {
                score += exact
            } else if tokens.contains(where: { $0.hasPrefix(queryToken) || queryToken.hasPrefix($0) }) {
                score += partial
            }
        }
        return score
    }

    private static func contains(_ phrase: [String], in tokens: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return false }
        if phrase.count == tokens.count { return phrase == tokens }
        for start in 0...(tokens.count - phrase.count) {
            if Array(tokens[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }
}

/// Persistent song-metadata cache, scoped per server.
///
/// Populated incrementally: search results are upserted as they are fetched, so
/// Siri never has to wait on a full-library scan and the store grows warm over
/// time. `clear(serverId:)` drops one server's entries on logout/switch.
@MainActor
final class LibraryMetadataStore {
    private let modelContainer: ModelContainer
    private lazy var context: ModelContext = ModelContext(modelContainer)

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Write

    func upsert(_ songs: [DisplayableSong], serverId: UUID) {
        guard !songs.isEmpty else { return }
        for song in songs {
            let id = CassetteEntityID(serverId: serverId, localId: song.id).rawValue
            var descriptor = FetchDescriptor<LibraryMetadataSong>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.apply(song, serverId: serverId)
            } else {
                context.insert(LibraryMetadataSong(song: song, serverId: serverId))
            }
        }
        try? context.save()
    }

    // MARK: - Read

    /// Local, rank-free substring search over the cached songs.
    func matching(_ query: String, serverId: UUID, limit: Int) -> [DisplayableSong] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        // Rank the *whole* cached set for this server. The previous bounded
        // `fetchLimit` was the "Siri plays the wrong song" bug: SwiftData returns rows
        // in an unspecified order, so capping the fetch (to ~100–200 rows) ranked an
        // arbitrary slice and silently dropped the requested track. The store is a
        // metadata cache (warmup is capped at ~1k entries), so ranking all of it in
        // memory stays cheap and always correct.
        let descriptor = FetchDescriptor<LibraryMetadataSong>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []

        return candidates
            .map { candidate in
                let song = candidate.toDisplayableSong()
                return (song: song, score: SiriSongSearchRanker.score(song, query: q))
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.song)
    }

    func song(id: String, serverId: UUID) -> DisplayableSong? {
        var descriptor = FetchDescriptor<LibraryMetadataSong>(
            predicate: #Predicate {
                $0.songId == id && $0.serverId == serverId
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.toDisplayableSong()
    }

    func count(serverId: UUID) -> Int {
        var descriptor = FetchDescriptor<LibraryMetadataSong>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Clear

    func clear(serverId: UUID) {
        let descriptor = FetchDescriptor<LibraryMetadataSong>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        guard let songs = try? context.fetch(descriptor) else { return }
        for song in songs { context.delete(song) }
        try? context.save()
    }

}
