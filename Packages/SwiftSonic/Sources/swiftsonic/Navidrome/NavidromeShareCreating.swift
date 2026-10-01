// NavidromeShareCreating.swift — SwiftSonic
//
// Protocol for Navidrome's native share-creation endpoint.
// This endpoint is NOT part of the Subsonic/OpenSubsonic spec — Navidrome's
// Subsonic `createShare` accepts only id/description/expires and ignores
// download/format flags. The native `/api/share` endpoint is where the
// `downloadable` / `format` / `maxBitRate` fields actually live.

import Foundation

/// Navidrome-specific REST API for creating public shares.
///
/// Navidrome's Subsonic `createShare` ignores the download/format parameters that the
/// OpenSubsonic extension describes. Share-level options (downloadable, transcode format,
/// bit-rate cap) are only honoured by the native REST endpoint, which uses Navidrome's
/// own JWT authentication rather than Subsonic's salted tokens.
public protocol NavidromeShareCreating: Sendable {

    /// Authenticates against Navidrome's native REST API and returns a JWT token.
    ///
    /// Calls `POST {baseURL}/auth/login` with a JSON body containing the credentials.
    func authenticate(
        baseURL: URL,
        username: String,
        password: String
    ) async throws -> String

    /// Creates a public share for the given resource IDs.
    ///
    /// Calls `POST {baseURL}/api/share` with a JSON body. The returned URL points at
    /// Navidrome's public share player (`{baseURL}/share/{id}`).
    ///
    /// - Parameters:
    ///   - baseURL: The root URL of the Navidrome server (e.g. `https://music.example.com`).
    ///   - token: A valid JWT token obtained from ``authenticate``.
    ///   - resourceIDs: The IDs of the media items to share (songs, albums, or playlists).
    ///   - description: An optional description shown to visitors.
    ///   - downloadAllowed: When `true`, visitors may download files from the share.
    ///   - expires: An optional expiry date; when `nil` Navidrome applies its server default.
    /// - Returns: The public share URL.
    /// - Throws: ``NavidromeNativeAPIError`` on failure.
    func createShare(
        baseURL: URL,
        token: String,
        resourceIDs: [String],
        description: String?,
        downloadAllowed: Bool,
        expires: Date?
    ) async throws -> URL
}