// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// A song in the Cassette library.
///
/// Required schema properties for `.audio.song` are `title`, `artistName`,
/// `composerName`, `albumTitle`, `artists`, `album`, `composers`, and
/// `internationalStandardRecordingCode` — verified against
/// `AppIntentSchemas.sqlite`. `artists` and `composers` are non-optional
/// arrays, so unknown credits become `[]` rather than `nil`.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.song)
struct CassetteSongEntity: IndexedEntity {
    static let defaultQuery = CassetteSongQuery()

    // MARK: Schema properties

    var title: String
    var artistName: String
    var composerName: String?
    var albumTitle: String?
    var artists: [CassetteArtistEntity]
    // Keep this wrapper explicit. With some Xcode 27 beta toolchains the schema
    // macro emits `@Property` into a peer generated-source file and type-checks
    // that file before CassetteAlbumEntity's AppEntity conformance is visible,
    // producing a spurious `_IntentValue` error.
    @Property
    var album: CassetteAlbumEntity?
    var composers: [CassetteArtistEntity]
    var internationalStandardRecordingCode: String?

    // MARK: Entity properties

    let id: String
    /// Display-only; the schema has no duration requirement.
    var duration: TimeInterval

    var displayRepresentation: DisplayRepresentation {
        var synonyms: [LocalizedStringResource] = [
            "\(title) by \(artistName)"
        ]
        // Include the album so Siri can disambiguate a same-titled single from the
        // album version ("Billie Jean" single vs "Thriller").
        let subtitle: LocalizedStringResource
        if let albumTitle, !albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subtitle = "\(artistName) · \(albumTitle)"
            synonyms.append("\(title) from \(albumTitle)")
            synonyms.append("\(title) on \(albumTitle)")
        } else {
            subtitle = "\(artistName)"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle,
            image: DisplayRepresentation.Image(systemName: "music.note"),
            synonyms: synonyms
        )
    }
}

// MARK: - Equatable / Hashable

@available(iOS 27.0, macOS 27.0, *)
extension CassetteSongEntity: Equatable {
    static func == (lhs: CassetteSongEntity, rhs: CassetteSongEntity) -> Bool { lhs.id == rhs.id }
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteSongEntity: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
