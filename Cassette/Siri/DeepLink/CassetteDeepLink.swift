// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Parses Cassette's own `cassette://` deep links into namespaced entity ids.
///
/// Shape: `cassette://<kind>/<serverId>/<localId>`, where `<kind>` is one of
/// `song`, `album`, `artist`, or `playlist`. `AudioSearch.Criteria.url` hands
/// these URLs back when Siri resolves onscreen or shared content.
nonisolated enum CassetteDeepLink {
    enum Kind: Sendable {
        case song
        case album
        case artist
        case playlist
    }

    static func parse(_ url: URL) -> (kind: Kind, id: CassetteEntityID)? {
        guard url.scheme?.lowercased() == "cassette" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let serverId = UUID(uuidString: parts[0]) else { return nil }

        let id = CassetteEntityID(serverId: serverId, localId: parts[1])
        switch host {
        case "song": return (.song, id)
        case "album": return (.album, id)
        case "artist": return (.artist, id)
        case "playlist": return (.playlist, id)
        default: return nil
        }
    }

    /// Builds the URL for an entity, used by onscreen awareness and sharing.
    static func url(kind: Kind, id: CassetteEntityID) -> URL? {
        let raw: String
        switch kind {
        case .song: raw = "song"
        case .album: raw = "album"
        case .artist: raw = "artist"
        case .playlist: raw = "playlist"
        }
        return URL(string: "cassette://\(raw)/\(id.serverId.uuidString)/\(id.localId)")
    }
}
