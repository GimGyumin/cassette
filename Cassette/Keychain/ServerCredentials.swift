// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

// IMPORTANT: Never persist outside of Keychain.
nonisolated struct ServerCredentials: Codable, Sendable {
    let password: String
    /// Jellyfin-scoped token obtained through Quick Connect. Used only with Jellyfin when no
    /// password was supplied and remains in Keychain alongside the Jellyfin token copy.
    let jellyfinAccessToken: String?
    /// Custom HTTP headers injected on all requests (e.g. Cloudflare Access tokens).
    /// Treated as secrets — never logged, never stored outside Keychain.
    let customHeaders: [String: String]

    init(
        password: String,
        customHeaders: [String: String],
        jellyfinAccessToken: String? = nil
    ) {
        self.password = password
        self.jellyfinAccessToken = jellyfinAccessToken
        self.customHeaders = customHeaders
    }

    static func keychainKey(for serverId: UUID) -> String {
        "cassette.server.\(serverId.uuidString)"
    }
}

extension ServerCredentials: CustomStringConvertible {
    var description: String { "ServerCredentials(password: [REDACTED], jellyfinAccessToken: [REDACTED], customHeaders: [REDACTED])" }
}

extension ServerCredentials: CustomDebugStringConvertible {
    var debugDescription: String { "ServerCredentials(password: [REDACTED], jellyfinAccessToken: [REDACTED], customHeaders: [REDACTED])" }
}
