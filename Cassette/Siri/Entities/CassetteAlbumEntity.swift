// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// An album in the Cassette library.
///
/// Required schema properties for `.audio.album` are `title`, `artistName`,
/// `artists`, and the optional `universalProductCode` — verified against
/// `AppIntentSchemas.sqlite`.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.album)
struct CassetteAlbumEntity: IndexedEntity {
    static let defaultQuery = CassetteAlbumQuery()

    // MARK: Schema properties

    var title: String
    var artistName: String
    var artists: [CassetteArtistEntity]
    var universalProductCode: String?

    // MARK: Entity properties

    let id: String

    var displayRepresentation: DisplayRepresentation {
        let synonyms: [LocalizedStringResource] = [
            "album \(title)",
            "\(artistName) album \(title)"
        ]
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(artistName)",
            image: DisplayRepresentation.Image(systemName: "opticaldisc"),
            synonyms: synonyms
        )
    }
}

// MARK: - Equatable / Hashable

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAlbumEntity: Equatable {
    static func == (lhs: CassetteAlbumEntity, rhs: CassetteAlbumEntity) -> Bool { lhs.id == rhs.id }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAlbumEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
