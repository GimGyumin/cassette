// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Adopts the `.audio.updateAudioAffinity` schema (“like this song”).
///
/// Cassette has no dislike state: `dislike` deliberately maps onto
/// “remove the favorite”, the same as `unset`.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.updateAudioAffinity)
struct CassetteUpdateAudioAffinityIntent {
    static let title: LocalizedStringResource = "Like Audio Item"

    // MARK: Schema parameters

    var affinityState: CassetteAffinityState
    var target: CassetteAudioItem

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SiriBridge.waitUntilReady()
        guard let favorites = await SiriBridge.favoritesProvider?() else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.serviceUnavailable)
        }
        guard let (type, itemId, title) = resolveTarget() else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.unsupportedTarget)
        }
        guard let catalog = await SiriBridge.catalogProvider?(),
              await targetExists(in: catalog) else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.noAudioEntity)
        }

        switch affinityState {
        case .like:
            try await favorites.star(itemType: type, itemId: itemId)
            return .result(dialog: IntentDialog("Liked \(title)."))
        case .dislike, .unset:
            try await favorites.unstar(itemType: type, itemId: itemId)
            return .result(dialog: IntentDialog("Removed the favorite for \(title)."))
        }
    }

    @MainActor
    private func targetExists(in catalog: any SiriCatalogServiceProtocol) async -> Bool {
        guard let id = target.entityID else { return false }
        switch target {
        case .song: return await catalog.song(id: id) != nil
        case .album: return await catalog.album(id: id) != nil
        case .artist: return await catalog.artist(id: id) != nil
        case .playlist: return false
        }
    }

    @MainActor
    private func resolveTarget() -> (FavoriteType, String, String)? {
        guard let id = target.entityID else { return nil }
        switch target {
        case .song(let song): return (.song, id.localId, song.title)
        case .album(let album): return (.album, id.localId, album.title)
        case .artist(let artist): return (.artist, id.localId, artist.name)
        case .playlist: return nil
        }
    }
}
