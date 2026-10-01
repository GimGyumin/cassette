// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Adopts the `.audio.addToPlaylist` schema. Appends a song to a playlist via
/// the existing `PlaylistService`; DTO conversion stays in the catalog.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct CassetteAddToPlaylistIntent {
    static let title: LocalizedStringResource = "Add to Playlist"

    // MARK: Schema parameters

    var audioEntity: CassetteAudioItem
    var playlist: CassettePlaylistEntity

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard case .song(let song) = audioEntity else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.unsupportedTarget)
        }
        guard let songID = CassetteEntityID(rawValue: song.id),
              let playlistID = CassetteEntityID(rawValue: playlist.id) else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.unsupportedTarget)
        }

        guard songID.serverId == playlistID.serverId,
              let catalog = await SiriBridge.catalogProvider?(),
              let record = await catalog.songRecord(id: songID),
              await catalog.playlist(id: playlistID) != nil else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.noAudioEntity)
        }
        guard let playlists = await SiriBridge.playlistProvider?() else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.serviceUnavailable)
        }

        try await playlists.addTracks(playlistId: playlistID.localId, songs: [record])
        return .result(dialog: IntentDialog("Added \(song.title) to \(playlist.title)."))
    }
}
