// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Namespaced identifier for every Cassette AppEntity: `"{serverId}:{localId}"`.
///
/// Cassette is multi-server: a Subsonic/OpenSubsonic song, album, artist, or
/// playlist id is only unique *within* one server, so every entity id carries
/// its server scope. Without the prefix, two servers that both expose a song
/// called `"1234"` would collide in Siri, Spotlight, and intent donations.
nonisolated struct CassetteEntityID: Hashable, Sendable, CustomStringConvertible {
    let serverId: UUID
    let localId: String

    init(serverId: UUID, localId: String) {
        self.serverId = serverId
        self.localId = localId
    }

    /// Parses `"{serverId}:{localId}"`. The server id is a UUID, so the *first*
    /// colon is always the separator and the local id may itself contain colons.
    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let serverPart = String(rawValue[rawValue.startIndex..<separator])
        let localPart = String(rawValue[rawValue.index(after: separator)...])
        guard !localPart.isEmpty, let serverId = UUID(uuidString: serverPart) else { return nil }
        self.serverId = serverId
        self.localId = localPart
    }

    var rawValue: String { "\(serverId.uuidString):\(localId)" }
    var description: String { rawValue }
}
