// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Wraps Navidrome's `createShare` API and returns a public URL.
enum ShareService {
    /// Creates a share via SwiftSonic's `createShare` and returns the public URL.
    static func createShare(
        id: String,
        options: ShareOptions,
        client: SwiftSonicClient
    ) async throws -> URL {
        var description: String? = nil
        var desc = options.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc?.isEmpty == true { desc = nil }
        description = desc

        let shares = try await client.createShare(
            ids: [id],
            description: description,
            expires: options.expires,
            allowDownloads: options.allowDownloads,
            originalFormat: options.shareOriginal
        )
        guard let url = validatedPublicURL(shares.first?.url) else {
            throw ShareError.invalidShareURL
        }
        return url
    }

    static func validatedPublicURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum ShareError: LocalizedError {
    case invalidShareURL

    var errorDescription: String? {
        switch self {
        case .invalidShareURL:
            return String(localized: "Failed to create share link", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Error: share link creation failed")
        }
    }
}

// MARK: - SwiftSonicClient convenience

extension SwiftSonicClient {
    /// Creates a share for a single item and returns the public URL.
    func createShareURL(
        id: String,
        options: ShareOptions
    ) async throws -> URL {
        try await ShareService.createShare(id: id, options: options, client: self)
    }
}
