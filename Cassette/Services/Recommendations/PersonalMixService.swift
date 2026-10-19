// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftSonic

// MARK: - Models

nonisolated enum PersonalMixKind: String, Sendable, Hashable, CaseIterable {
    case newMusic
    case heavyRotation
    case essentials
    case getUp
    case chill
    case focus

    var localizationKey: String {
        switch self {
        case .newMusic: return "New Music"
        case .heavyRotation: return "Heavy Rotation"
        case .essentials: return "Your Essentials"
        case .getUp: return "Get Up!"
        case .chill: return "Chill"
        case .focus: return "Focus"
        }
    }

    /// Apple Music–style portrait card gradient (top → bottom), hex pairs.
    var gradientHexes: (top: String, bottom: String) {
        switch self {
        case .newMusic: return ("#5B8DEF", "#1B3A6B")
        case .heavyRotation: return ("#E85D4C", "#6B1A14")
        case .essentials: return ("#C44B9F", "#4A1638")
        case .getUp: return ("#F0A202", "#8B3A00")
        case .chill: return ("#3DB8A0", "#0F3D36")
        case .focus: return ("#62D6D1", "#302478")
        }
    }
}

nonisolated struct PersonalMix: Identifiable, Sendable, Hashable {
    let kind: PersonalMixKind
    let tracks: [DisplayableSong]
    /// Up to ~6 artist names for the card subtitle.
    let artistNames: [String]
    var updatedAt: Date = Date()

    var id: String { kind.rawValue }
}

// MARK: - Service

actor PersonalMixService {
    private let libraryService: any LibraryServiceProtocol
    private let statsService: StatsService
    private let serverState: ServerState?
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0

    private var cached: [PersonalMix] = []
    private var cachedAt: Date?
    private var cachedServerId: String?
    /// `true` only after a full (unlimited) build finished — partial `limit:` calls must not freeze the shelf.
    private var cachedComplete = false
    private static let ttl: TimeInterval = 90
    private static let minTracks = 5
    private static let targetTracks = 35
    private static let subtitleArtistLimit = 6

    private static let getUpGenres = [
        "dance", "electronic", "edm", "house", "hip-hop", "hip hop",
        "k-pop", "kpop", "pop", "rock", "disco", "funk"
    ]
    private static let chillGenres = [
        "ambient", "jazz", "acoustic", "r&b", "rnb", "indie",
        "soul", "lo-fi", "lofi", "classical", "chill", "folk"
    ]

    init(libraryService: any LibraryServiceProtocol, statsService: StatsService, serverState: ServerState? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.serverState = serverState
        self.libraryService = libraryService
        self.statsService = statsService
        self.now = now
    }

    func mixes(serverId: String?, forceRefresh: Bool = false, limit: Int? = nil) async -> [PersonalMix] {
        let identity = await requestIdentity(serverId: serverId)
        guard serverState == nil || identity != nil else { return [] }
        if cachedServerId != serverId || forceRefresh || cachedAt.map({ now().timeIntervalSince($0) >= Self.ttl }) == true {
            clearCache(); cachedServerId = serverId
        }
        let revision = generation
        if !forceRefresh,
           let cachedAt,
           now().timeIntervalSince(cachedAt) < Self.ttl,
           cachedServerId == serverId,
           !cached.isEmpty {
            if let limit {
                return Array(cached.prefix(limit))
            }
            if cachedComplete {
                return cached
            }
            // Partial progressive cache — fall through and finish remaining kinds.
        }

        if forceRefresh {
            cached = []
            cachedAt = nil
            cachedComplete = false
        }

        // Sequential builders — five `async let` fans out dozens of getAlbum / getSongsByGenre /
        // getTopSongs on plain HTTP and can RST the CFNetwork pool (HTTP/2 / QUIC parse failures).
        // Callers can pass `limit: 1` to paint the first card, then call again without a limit.
        let kinds: [PersonalMixKind] = [.newMusic, .heavyRotation, .essentials, .getUp, .chill, .focus]
        var built = cached
        let have = Set(built.map(\.kind))

        for kind in kinds {
            guard await isCurrent(identity, generation: revision) else { return [] }
            if let limit, built.count >= limit { break }
            if have.contains(kind) { continue }
            let mix: PersonalMix?
            switch kind {
            case .newMusic: mix = await buildNewMusic()
            case .heavyRotation: mix = await buildHeavyRotation(serverId: serverId)
            case .essentials: mix = await buildEssentials(serverId: serverId)
            case .getUp: mix = await buildGenreMix(kind: .getUp, genres: Self.getUpGenres)
            case .chill: mix = await buildGenreMix(kind: .chill, genres: Self.chillGenres)
            case .focus: mix = await buildGenreMix(kind: .focus, genres: ["ambient", "classical", "instrumental", "lo-fi"])
            }
            if let mix {
                built.append(mix)
            }
        }

        guard await isCurrent(identity, generation: revision) else { return [] }
        cached = built
        cachedServerId = serverId
        if limit == nil {
            cachedComplete = true
            cachedAt = now()
        } else {
            cachedComplete = false
            // Soft TTL so a crashed progressive fill can retry soon.
            if cachedAt == nil { cachedAt = now() }
        }
        Logger.recommendations.debug("Personal mixes: \(built.count, privacy: .public) card(s)")
        if let limit { return Array(built.prefix(limit)) }
        return built
    }

    private func requestIdentity(serverId: String?) async -> ServerRequestIdentity? {
        guard let serverState else { return nil }
        return await MainActor.run {
            guard let sid = serverState.activeServer?.id, sid.uuidString == serverId else { return nil }
            return try? serverState.requestIdentity(for: sid)
        }
    }

    private func isCurrent(_ identity: ServerRequestIdentity?, generation revision: UInt64) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let serverState, let identity {
            guard await MainActor.run(body: { serverState.requestIsCurrent(identity) }) else { return false }
        }
        return revision == generation
    }

    func clearCache() {
        generation &+= 1
        cached = []
        cachedAt = nil
        cachedServerId = nil
        cachedComplete = false
    }

    /// Rebuilds (or returns cached) a single mix kind — used by mix detail refresh.
    func mix(kind: PersonalMixKind, serverId: String?, forceRefresh: Bool = false) async -> PersonalMix? {
        let identity = await requestIdentity(serverId: serverId)
        guard serverState == nil || identity != nil else { return nil }
        if cachedServerId != serverId || forceRefresh || cachedAt.map({ now().timeIntervalSince($0) >= Self.ttl }) == true {
            clearCache(); cachedServerId = serverId
        }
        let revision = generation
        if !forceRefresh,
           let cachedAt,
           now().timeIntervalSince(cachedAt) < Self.ttl,
           cachedServerId == serverId,
           let hit = cached.first(where: { $0.kind == kind }) {
            return hit
        }

        let built: PersonalMix?
        switch kind {
        case .newMusic: built = await buildNewMusic()
        case .heavyRotation: built = await buildHeavyRotation(serverId: serverId)
        case .essentials: built = await buildEssentials(serverId: serverId)
        case .getUp: built = await buildGenreMix(kind: .getUp, genres: Self.getUpGenres)
        case .chill: built = await buildGenreMix(kind: .chill, genres: Self.chillGenres)
        case .focus: built = await buildGenreMix(kind: .focus, genres: ["ambient", "classical", "instrumental", "lo-fi"])
        }

        guard await isCurrent(identity, generation: revision) else { return nil }
        if let built {
            if let idx = cached.firstIndex(where: { $0.kind == kind }) {
                cached[idx] = built
            } else {
                cached.append(built)
            }
            cachedServerId = serverId
            if cachedAt == nil { cachedAt = now() }
        } else {
            cached.removeAll { $0.kind == kind }
        }
        return built
    }

    // MARK: - Builders

    private func buildNewMusic() async -> PersonalMix? {
        let albums: [AlbumID3]
        do {
            albums = try await libraryService.recentlyAddedAlbums(size: 10)
        } catch {
            if !UserFacingError.isCancellation(error) {
                Logger.recommendations.error("New Music albums failed: \(error, privacy: .public)")
            }
            return nil
        }
        guard !albums.isEmpty else { return nil }

        var tracks: [DisplayableSong] = []
        var seen = Set<String>()
        for album in albums.prefix(8) {
            guard tracks.count < Self.targetTracks else { break }
            guard let songs = try? await libraryService.album(id: album.id).song else { continue }
            for song in songs {
                let display = DisplayableSong(from: song)
                guard seen.insert(display.id).inserted else { continue }
                tracks.append(display)
                if tracks.count >= Self.targetTracks { break }
            }
        }
        return makeMix(kind: .newMusic, tracks: tracks)
    }

    private func buildHeavyRotation(serverId: String?) async -> PersonalMix? {
        var tracks: [DisplayableSong] = []
        var seen = Set<String>()

        if let serverId {
            let events = await statsService.recentEvents(limit: 250, serverId: serverId)
            var counts: [String: (count: Int, event: PlaybackEventDTO)] = [:]
            for event in events {
                var entry = counts[event.trackId] ?? (0, event)
                entry.count += 1
                entry.event = event
                counts[event.trackId] = entry
            }
            let ranked = counts.values.sorted { $0.count > $1.count }
            for item in ranked {
                guard seen.insert(item.event.trackId).inserted else { continue }
                tracks.append(Self.song(from: item.event))
                if tracks.count >= Self.targetTracks { break }
            }
        }

        if tracks.count < Self.minTracks {
            let albums = (try? await libraryService.mostPlayedAlbums(size: 8)) ?? []
            for album in albums {
                guard tracks.count < Self.targetTracks else { break }
                guard let songs = try? await libraryService.album(id: album.id).song else { continue }
                for song in songs.shuffled().prefix(6) {
                    let display = DisplayableSong(from: song)
                    guard seen.insert(display.id).inserted else { continue }
                    tracks.append(display)
                    if tracks.count >= Self.targetTracks { break }
                }
            }
        }

        return makeMix(kind: .heavyRotation, tracks: tracks)
    }

    private func buildEssentials(serverId: String?) async -> PersonalMix? {
        guard let serverId else { return nil }

        var artistNames: [String] = []
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let wrapped = await statsService.wrappedData(
            for: .year(year),
            serverId: serverId,
            calendar: calendar
        )
        if !wrapped.topArtists.isEmpty {
            artistNames = wrapped.topArtists.prefix(3).map(\.name)
        } else {
            let events = await statsService.recentEvents(limit: 300, serverId: serverId)
            var counts: [String: (count: Int, name: String)] = [:]
            for event in events {
                let key = event.artistId ?? event.artistName
                var entry = counts[key] ?? (0, event.artistName)
                entry.count += 1
                counts[key] = entry
            }
            artistNames = counts.values
                .sorted { $0.count > $1.count }
                .prefix(3)
                .map(\.name)
        }
        guard !artistNames.isEmpty else { return nil }

        var tracks: [DisplayableSong] = []
        var seen = Set<String>()
        for name in artistNames {
            let songs = (try? await libraryService.topSongs(artist: name, count: 6)) ?? []
            for song in songs {
                guard seen.insert(song.id).inserted else { continue }
                tracks.append(song)
                if tracks.count >= Self.targetTracks { break }
            }
            if tracks.count >= Self.targetTracks { break }
        }

        // topSongs can be empty on bare servers — fall back to recent plays by those artists.
        if tracks.count < Self.minTracks {
            let events = await statsService.recentEvents(limit: 300, serverId: serverId)
            let nameSet = Set(artistNames.map { $0.lowercased() })
            for event in events {
                guard nameSet.contains(event.artistName.lowercased()) else { continue }
                guard seen.insert(event.trackId).inserted else { continue }
                tracks.append(Self.song(from: event))
                if tracks.count >= Self.targetTracks { break }
            }
        }

        return makeMix(kind: .essentials, tracks: tracks)
    }

    private func buildGenreMix(kind: PersonalMixKind, genres: [String]) async -> PersonalMix? {
        var tracks: [DisplayableSong] = []
        var seen = Set<String>()
        // Cap genre probes — a 12-genre fan-out per mix was saturating plain-HTTP CFNetwork.
        // Lowered to 2 to shrink the cold-start getSongsByGenre burst while still filling 35 tracks.
        let maxGenreCalls = 2
        var genreCalls = 0

        for genre in genres {
            guard tracks.count < Self.targetTracks else { break }
            guard genreCalls < maxGenreCalls else { break }
            genreCalls += 1
            let songs = (try? await libraryService.songsByGenre(genre, count: 20)) ?? []
            for song in songs {
                guard seen.insert(song.id).inserted else { continue }
                tracks.append(song)
                if tracks.count >= Self.targetTracks { break }
            }
        }

        if tracks.count < Self.minTracks {
            let random = (try? await libraryService.randomSongs(size: 80)) ?? []
            let needles = genres.map { $0.lowercased() }
            for song in random {
                let display = DisplayableSong(from: song)
                let hay = (display.genre ?? "").lowercased()
                guard needles.contains(where: { hay.contains($0) }) else { continue }
                guard seen.insert(display.id).inserted else { continue }
                tracks.append(display)
                if tracks.count >= Self.targetTracks { break }
            }
        }

        return makeMix(kind: kind, tracks: tracks.shuffled())
    }

    // MARK: - Helpers

    private func makeMix(kind: PersonalMixKind, tracks: [DisplayableSong]) -> PersonalMix? {
        guard tracks.count >= Self.minTracks else { return nil }
        let names = Self.uniqueArtistNames(from: tracks, limit: Self.subtitleArtistLimit)
        return PersonalMix(kind: kind, tracks: Array(tracks.prefix(Self.targetTracks)), artistNames: names, updatedAt: now())
    }

    private static func uniqueArtistNames(from tracks: [DisplayableSong], limit: Int) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for track in tracks {
            guard let raw = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let key = raw.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(raw)
            if names.count >= limit { break }
        }
        return names
    }

    private static func song(from event: PlaybackEventDTO) -> DisplayableSong {
        DisplayableSong(
            id: event.trackId,
            title: event.trackTitle,
            artist: event.artistName,
            albumId: event.albumId,
            albumName: event.albumTitle,
            artistId: event.artistId,
            genre: event.genre,
            duration: event.trackDuration
        )
    }
}
