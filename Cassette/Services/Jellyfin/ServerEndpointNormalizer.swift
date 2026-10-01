// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation

/// Accepts either a Navidrome server root or its optional `/jellyfin` API address.
/// OpenSubsonic always receives the root; JellyfinClient appends `/jellyfin` exactly once.
nonisolated enum ServerEndpointNormalizer {
    static func openSubsonicBaseURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        // A bare hostname (including a port or reverse-proxy path) uses TLS by default.
        // Explicit HTTP is preserved so the sign-in screen can request its confirmation.
        let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        components.scheme = scheme

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/jellyfin") {
            path.removeLast("/jellyfin".count)
            if path.isEmpty { path = "/" }
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func normalizedOpenSubsonicAddress(from input: String) -> String? {
        guard let url = openSubsonicBaseURL(from: input) else { return nil }
        var address = url.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }
}
