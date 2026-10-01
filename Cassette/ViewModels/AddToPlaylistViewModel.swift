// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

enum AddToPlaylistResult {
    case added
    case duplicate
    case failed
}

@MainActor
@Observable
final class AddToPlaylistViewModel {
    private(set) var playlists: [Playlist] = []
    private(set) var isLoading = false
    private(set) var addingToPlaylistIds: Set<String> = []

    private let songs: [DisplayableSong]
    private let playlistService: any PlaylistServiceProtocol
    private let toastService: ToastService

    init(song: DisplayableSong, playlistService: any PlaylistServiceProtocol, toastService: ToastService) {
        self.songs = [song]
        self.playlistService = playlistService
        self.toastService = toastService
    }

    init(songs: [DisplayableSong], playlistService: any PlaylistServiceProtocol, toastService: ToastService) {
        self.songs = songs
        self.playlistService = playlistService
        self.toastService = toastService
    }

    func load() async {
        isLoading = true
        defer {
            isLoading = false
        }
        do {
            playlists = try await playlistService.listPlaylists()
        } catch {
            Logger.playlist.error("AddToPlaylistViewModel: failed to load playlists: \(error)")
        }
    }

    /// Checks for a duplicate then adds. Returns `.duplicate` if the song is already in the
    /// playlist (caller shows confirmation), `.added` on success, `.failed` on error.
    func checkAndAdd(to playlist: Playlist) async -> AddToPlaylistResult {
        guard !addingToPlaylistIds.contains(playlist.id) else { return .failed }
        addingToPlaylistIds.insert(playlist.id)
        defer { addingToPlaylistIds.remove(playlist.id) }

        do {
            let detail = try await playlistService.getPlaylist(id: playlist.id)
            let existingIDs = Set((detail.entry ?? []).map(\.id))
            let missingSongs = songs.filter { !existingIDs.contains($0.id) }
            if missingSongs.isEmpty { return .duplicate }
            return await performAdd(to: playlist, songs: missingSongs)
        } catch {
            Logger.playlist.error("AddToPlaylistViewModel: duplicate check failed for playlist \(playlist.id): \(error)")
            // Fallback: proceed with add
        }

        return await performAdd(to: playlist, songs: songs)
    }

    /// Adds without a duplicate check — used after the user confirms "Add Anyway",
    /// or when adding to a newly-created (empty) playlist.
    @discardableResult
    func forceAdd(to playlist: Playlist) async -> Bool {
        guard !addingToPlaylistIds.contains(playlist.id) else { return false }
        addingToPlaylistIds.insert(playlist.id)
        defer { addingToPlaylistIds.remove(playlist.id) }
        return await performAdd(to: playlist, songs: songs) == .added
    }

    func handleNewPlaylistCreated(_ created: PlaylistWithSongs) async -> Bool {
        let summary = Playlist(
            id: created.id,
            name: created.name,
            songCount: created.songCount,
            duration: created.duration,
            comment: created.comment,
            owner: created.owner,
            isPublic: created.isPublic,
            created: created.created,
            changed: created.changed,
            coverArt: created.coverArt
        )
        playlists.insert(summary, at: 0)
        return await forceAdd(to: summary)
    }

    // MARK: - Private

    private func performAdd(
        to playlist: Playlist,
        songs songsToAdd: [DisplayableSong]
    ) async -> AddToPlaylistResult {
        guard !songsToAdd.isEmpty else { return .failed }
        do {
            try await playlistService.addTracks(
                playlistId: playlist.id,
                songs: songsToAdd.map { $0.asSong() }
            )
            toastService.showConfirmation(
                String(localized: "\(songsToAdd.count) songs added", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: playlist.name,
                coverArtId: playlist.coverArt,
                action: .navigateToPlaylist(id: playlist.id, name: playlist.name, coverArtId: playlist.coverArt)
            )
            return .added
        } catch {
            Logger.playlist.error("AddToPlaylistViewModel: failed to add \(songsToAdd.count) song(s) to playlist \(playlist.id): \(error)")
            toastService.showError("Failed to add to \(playlist.name)")
            return .failed
        }
    }
}
