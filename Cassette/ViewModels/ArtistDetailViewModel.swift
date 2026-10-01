// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

@Observable
@MainActor
final class ArtistDetailViewModel {
    var artist: ArtistID3?
    var artistBiography: String?
    /// MusicBrainz ID from `getArtistInfo2` (used for profile facts / enrichment).
    var musicBrainzId: String?
    var isLoading = false
    var isPlayLoading = false
    var error: UserFacingError?
    var similarArtists: [SimilarArtistRecommendation] = []
    var isLoadingSimilarArtists = false
    var outOfLibraryArtistImages: [String: URL?] = [:]
    /// Most-played songs (getTopSongs). Empty on bare self-hosted servers → the view hides the section.
    var topSongs: [DisplayableSong] = []
    /// Starts true so the section shows a skeleton until the first load resolves (then empty → hidden).
    var isLoadingTopSongs = true

    private let artistId: String
    private let libraryService: any LibraryServiceProtocol
    private let recommendationService: RecommendationService
    private let imageResolver: ExternalArtistImageResolver
    private var loadGeneration = 0
    private var outOfLibraryImagesTask: Task<Void, Never>?
    /// Prevents re-fetch when pushing album detail and popping back (SwiftUI re-runs `.task`).
    private var didLoadArtist = false
    private var didLoadTopSongs = false
    private var didLoadSimilarArtists = false

    init(
        artistId: String,
        libraryService: any LibraryServiceProtocol,
        recommendationService: RecommendationService,
        imageResolver: ExternalArtistImageResolver
    ) {
        self.artistId = artistId
        self.libraryService = libraryService
        self.recommendationService = recommendationService
        self.imageResolver = imageResolver
    }

    /// Most common genres across the artist's albums (library tags).
    var primaryGenres: [String] {
        var counts: [String: Int] = [:]
        for album in artist?.album ?? [] {
            if let genre = album.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
                counts[genre, default: 0] += 2
            }
            for item in album.genres ?? [] {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                counts[name, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(4)
            .map(\.key)
    }

    func load(force: Bool = false) async {
        if didLoadArtist, !force, artist != nil { return }

        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoading = true
        error = nil
        do {
            let fetched = try await libraryService.artist(id: artistId)
            guard generation == loadGeneration else { return }
            artist = fetched
            var artistMBID: String?
            if let info = try? await libraryService.getArtistInfo(forArtistID: artistId, count: 0) {
                guard generation == loadGeneration else { return }
                artistMBID = info.musicBrainzId
                musicBrainzId = info.musicBrainzId
                if let bio = info.biography?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bio.isEmpty {
                    artistBiography = Self.plainText(from: bio)
                } else {
                    artistBiography = nil
                }
            } else if generation == loadGeneration {
                artistBiography = nil
                musicBrainzId = nil
            }
            guard generation == loadGeneration else { return }
            await enrichBiographyIfNeeded(musicBrainzId: artistMBID, generation: generation)
            if generation == loadGeneration {
                didLoadArtist = true
            }
        } catch is CancellationError {
            // Superseded / view torn down — leave prior content if any.
        } catch {
            guard generation == loadGeneration else { return }
            self.error = UserFacingError.from(error)
        }
        if generation == loadGeneration {
            isLoading = false
        }
    }

    /// Disk cache (with TTL refresh) → Wikipedia / MusicBrainz.
    private func enrichBiographyIfNeeded(musicBrainzId: String?, generation: Int) async {
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        let existing = artistBiography?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existing.isEmpty, let name = artist?.name, !name.isEmpty else { return }

        let cached = await DescriptionCache.shared.lookup(
            kind: .artist,
            name: name,
            musicBrainzId: musicBrainzId
        )
        guard generation == loadGeneration else { return }
        if let cached {
            artistBiography = cached.text
            if !cached.needsRefresh { return }
        }

        if let external = await ExternalDescriptionService.shared.artistDescription(
            artistName: name,
            musicBrainzId: musicBrainzId
        ), !external.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard generation == loadGeneration else { return }
            artistBiography = external
            await DescriptionCache.shared.store(
                external,
                kind: .artist,
                name: name,
                musicBrainzId: musicBrainzId,
                source: .external
            )
        }
    }

    private static func plainText(from htmlOrText: String) -> String {
        htmlOrText
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Top songs (getTopSongs takes the artist NAME) — call after `load()` so `artist?.name` is set.
    func loadTopSongs(force: Bool = false) async {
        if didLoadTopSongs, !force { return }
        guard let name = artist?.name else { isLoadingTopSongs = false; return }
        let generation = loadGeneration
        isLoadingTopSongs = true
        defer {
            if generation == loadGeneration { isLoadingTopSongs = false }
        }
        do {
            let songs = try await libraryService.topSongs(artist: name, count: 25)
            guard generation == loadGeneration else { return }
            topSongs = songs
            didLoadTopSongs = true
        } catch is CancellationError {
            return
        } catch {
            Logger.recommendations.warning("topSongs failed for \(self.artistId): \(error)")
            guard generation == loadGeneration else { return }
            topSongs = []
            didLoadTopSongs = true
        }
    }

    // Called from the view's .task after load() returns so artist loading and
    // index/network calls from similar artists never compete on the same server.
    func loadSimilarArtists(force: Bool = false) async {
        if didLoadSimilarArtists, !force, !similarArtists.isEmpty { return }
        let generation = loadGeneration
        isLoadingSimilarArtists = true
        if force { similarArtists = [] }
        defer {
            if generation == loadGeneration { isLoadingSimilarArtists = false }
        }
        do {
            let results = try await recommendationService.similarArtists(to: artistId)
            guard generation == loadGeneration else { return }
            similarArtists = results
            didLoadSimilarArtists = true
        } catch is CancellationError {
            return
        } catch {
            Logger.recommendations.warning("similarArtists failed for \(self.artistId): \(error)")
            if generation == loadGeneration { didLoadSimilarArtists = true }
        }
        guard generation == loadGeneration else { return }
        outOfLibraryImagesTask?.cancel()
        outOfLibraryImagesTask = Task { await loadOutOfLibraryImages(generation: generation) }
    }

    /// Pull-to-refresh — reload artist, top songs, and similar artists.
    func reloadAll() async {
        await load(force: true)
        await loadTopSongs(force: true)
        await loadSimilarArtists(force: true)
    }

    private func loadOutOfLibraryImages(generation: Int) async {
        for rec in similarArtists where !rec.inLibrary {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let url = await imageResolver.resolveImageURL(for: rec)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            outOfLibraryArtistImages[rec.id] = url
        }
    }
}
