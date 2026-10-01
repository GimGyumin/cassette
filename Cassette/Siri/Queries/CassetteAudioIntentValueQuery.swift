// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation
import MediaIntents

/// Bridges `AudioSearch` — the structured form of a Siri audio request — to
/// Cassette's catalog. Returns the union `CassetteAudioItem` so a single query
/// covers songs, albums, artists, and playlists.
///
/// Mirrors Apple's CosmoTunes `AudioIntentValueQuery` (WWDC26 session 343).
@available(iOS 27.0, macOS 27.0, *)
extension CassetteAudioItem {
    struct AudioIntentValueQuery {
        func values(for input: AudioSearch) async throws -> [CassetteAudioItem] {
            await SiriBridge.waitUntilReady()
            switch input.criteria {
            case .searchQuery(let query):
                return try await searchResults(for: query)
            case .url(let urls):
                return await results(for: urls)
            case .unspecified:
                return await suggestedResults()
            @unknown default:
                return []
            }
        }

        private func searchResults(for query: String) async throws -> [CassetteAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            let songs = await catalog.songs(matching: query, limit: 10)
            let albums = await catalog.albums(matching: query, limit: 5)
            let artists = await catalog.artists(matching: query, limit: 5)
            let playlists = await catalog.playlists(matching: query, limit: 5)

            return songs.map(CassetteAudioItem.song)
                + albums.map(CassetteAudioItem.album)
                + artists.map(CassetteAudioItem.artist)
                + playlists.map(CassetteAudioItem.playlist)
        }

        private func suggestedResults() async -> [CassetteAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            return await catalog.suggestedSongs(limit: 10).map(CassetteAudioItem.song)
        }

        private func results(for urls: [URL]) async -> [CassetteAudioItem] {
            guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
            var items: [CassetteAudioItem] = []
            for url in urls {
                guard let ref = CassetteDeepLink.parse(url) else { continue }
                switch ref.kind {
                case .song:
                    if let song = await catalog.song(id: ref.id) { items.append(.song(song)) }
                case .album:
                    if let album = await catalog.album(id: ref.id) { items.append(.album(album)) }
                case .artist:
                    if let artist = await catalog.artist(id: ref.id) { items.append(.artist(artist)) }
                case .playlist:
                    if let playlist = await catalog.playlist(id: ref.id) { items.append(.playlist(playlist)) }
                }
            }
            return items
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAudioItem.AudioIntentValueQuery: IntentValueQuery {}
