// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// A playlist (Navidrome playlist) in the Cassette library.
///
/// Required schema properties for `.audio.playlist` are `title`, `owner`,
/// `createdByMe`, and `curatedForMe` — verified against
/// `AppIntentSchemas.sqlite`.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct CassettePlaylistEntity: IndexedEntity {
    static let defaultQuery = CassettePlaylistQuery()

    // MARK: Entity properties

    let id: String

    // MARK: Schema properties

    var title: String
    var owner: CassettePlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    /// Display-only; the schema has no track-count requirement.
    var trackCount: Int

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = [
            "\(title) playlist"
        ]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "^[\(trackCount) track](inflect: true)",
            image: DisplayRepresentation.Image(systemName: "music.note.list"),
            synonyms: synonyms
        )
    }
}

// MARK: - Equatable / Hashable

@available(iOS 27.0, macOS 27.0, *)
extension CassettePlaylistEntity: Equatable {
    static func == (lhs: CassettePlaylistEntity, rhs: CassettePlaylistEntity) -> Bool { lhs.id == rhs.id }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassettePlaylistEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
