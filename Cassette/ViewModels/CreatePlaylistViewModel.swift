// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

@MainActor
@Observable
final class CreatePlaylistViewModel {
    var name: String = ""
    var description: String = ""
    var isPublic: Bool = false
    /// Songs resolved by AI draft — added after create when non-empty.
    var pendingSongs: [Song] = []
    private(set) var isCreating: Bool = false

    private let playlistService: any PlaylistServiceProtocol
    private let toastService: ToastService

    init(playlistService: any PlaylistServiceProtocol, toastService: ToastService) {
        self.playlistService = playlistService
        self.toastService = toastService
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    func create() async -> PlaylistWithSongs? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        isCreating = true
        defer { isCreating = false }

        do {
            var playlist = try await playlistService.createPlaylist(
                name: trimmedName,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc
            )
            if isPublic {
                try await playlistService.updateVisibility(id: playlist.id, isPublic: true)
                playlist = try await playlistService.getPlaylist(id: playlist.id)
            }
            if !pendingSongs.isEmpty {
                try await playlistService.addTracks(playlistId: playlist.id, songs: pendingSongs)
                playlist = try await playlistService.getPlaylist(id: playlist.id)
            }
            toastService.showSuccess("Playlist created")
            return playlist
        } catch {
            Logger.playlist.error("Failed to create playlist: \(error)")
            toastService.showError("Failed to create playlist. Try again.")
            return nil
        }
    }
}
