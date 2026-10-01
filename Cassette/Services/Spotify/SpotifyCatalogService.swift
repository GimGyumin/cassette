// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// Matches Subsonic library tracks to the Spotify catalog for ISRC (Music Haptics / Now Playing).
/// Album notes and artist bios are not available from the Spotify Web API — use Wikipedia / MusicBrainz.
actor SpotifyCatalogService {
    static let shared = SpotifyCatalogService()

    private enum SpotifyHTTPError: Error, LocalizedError {
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .status(let code, let body):
                let snippet = body.prefix(180)
                return "HTTP \(code): \(snippet)"
            }
        }
    }

    private let session: URLSession
    private var isrcCache: [String: String] = [:]
    private var accessToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var clientId: String = ""
    private var clientSecret: String = ""
    private var credentialsRejected = false
    private var didLogCredentialsRejected = false
    /// Spotify Dev Mode now requires Premium on the app-owner account; stick for the session after 403.
    private var premiumRequiredBlocked = false
    private var didLogPremiumRequired = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Call when the user saves/clears Spotify credentials in Account settings.
    func setCredentials(clientId: String, clientSecret: String) {
        let id = Self.sanitizeCredential(clientId)
        let secret = Self.sanitizeCredential(clientSecret)
        let changed = id != self.clientId || secret != self.clientSecret
        self.clientId = id
        self.clientSecret = secret
        if changed {
            accessToken = nil
            tokenExpiresAt = .distantPast
            credentialsRejected = false
            didLogCredentialsRejected = false
            premiumRequiredBlocked = false
            didLogPremiumRequired = false
        }
    }

    /// Best-effort ISRC for system Music Haptics / Now Playing.
    func catalogISRC(title: String, artist: String?, album: String?) async -> String? {
        let key = "isrc|\(title)|\(artist ?? "")|\(album ?? "")".lowercased()
        if let cached = isrcCache[key] { return cached }
        if premiumRequiredBlocked { return nil }
        guard await ensureCredentialsLoaded() else {
            Logger.library.debug("Spotify ISRC skipped — Client ID/Secret not set")
            return nil
        }
        guard await validAccessToken() != nil else {
            Logger.library.warning("Spotify ISRC skipped — could not obtain access token")
            return nil
        }

        let query = Self.searchQuery(title: title, artist: artist, album: album)
        guard !query.isEmpty else { return nil }

        let market = (Locale.current.region?.identifier ?? "US").uppercased()
        guard var components = URLComponents(string: "https://api.spotify.com/v1/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "market", value: market),
        ]
        guard let url = components.url else { return nil }

        do {
            let data = try await authorizedGET(url)
            let response = try JSONDecoder().decode(SpotifySearchResponse.self, from: data)
            let tracks = response.tracks?.items ?? []
            let ranked = tracks.sorted {
                Self.trackMatchScore($0, title: title, artist: artist, album: album)
                    > Self.trackMatchScore($1, title: title, artist: artist, album: album)
            }
            for track in ranked {
                if let isrc = track.externalIds?.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !isrc.isEmpty {
                    isrcCache[key] = isrc
                    Logger.library.debug(
                        "Spotify ISRC ok isrc=\(isrc, privacy: .public) track=\(track.name, privacy: .public)"
                    )
                    return isrc
                }
                // Search hits sometimes omit ISRC — fetch the full track.
                if let isrc = await fetchTrackISRC(id: track.id), !isrc.isEmpty {
                    isrcCache[key] = isrc
                    Logger.library.debug(
                        "Spotify ISRC ok (detail) isrc=\(isrc, privacy: .public) track=\(track.name, privacy: .public)"
                    )
                    return isrc
                }
            }
            Logger.library.debug(
                "Spotify ISRC: no ISRC in \(tracks.count, privacy: .public) search hit(s) for \(title, privacy: .public)"
            )
        } catch {
            if case SpotifyHTTPError.status(403, let body) = error,
               body.localizedCaseInsensitiveContains("premium") {
                premiumRequiredBlocked = true
                if !didLogPremiumRequired {
                    didLogPremiumRequired = true
                    Logger.library.warning(
                        "Spotify Web API blocked: app owner needs Premium (Dev Mode). Falling back to MusicBrainz for ISRC. Spotify may take a few hours to recognize a new subscription — owner account must match the Developer Dashboard login."
                    )
                }
            } else {
                Logger.library.warning(
                    "Spotify ISRC lookup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return nil
    }

    // MARK: - Auth

    private func ensureCredentialsLoaded() async -> Bool {
        let id = Self.sanitizeCredential(
            UserDefaults.standard.string(forKey: AppleMusicSettings.spotifyClientIdKey) ?? ""
        )
        let secret = Self.sanitizeCredential(
            SensitiveSettingsStore.string(forKey: AppleMusicSettings.spotifyClientSecretKey) ?? ""
        )
        if id != clientId || secret != clientSecret {
            setCredentials(clientId: id, clientSecret: secret)
        }
        return !clientId.isEmpty && !clientSecret.isEmpty && !credentialsRejected
    }

    private func validAccessToken() async -> String? {
        if let accessToken, Date() < tokenExpiresAt.addingTimeInterval(-60) {
            return accessToken
        }
        return await fetchAccessToken()
    }

    private func fetchAccessToken() async -> String? {
        guard !clientId.isEmpty, !clientSecret.isEmpty, !credentialsRejected, !premiumRequiredBlocked else {
            return nil
        }
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return nil }

        // Spotify Client Credentials requires HTTP Basic (id:secret). Body-only client_id/secret
        // commonly returns HTTP 400 invalid_client even with valid dashboard credentials.
        let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                // Some edge secrets historically failed Basic — one body-credentials retry.
                if bodyText.localizedCaseInsensitiveContains("Failed to get client"),
                   let retryToken = await fetchAccessTokenViaBodyCredentials() {
                    return retryToken
                }
                let invalidClient = bodyText.localizedCaseInsensitiveContains("invalid_client")
                    || bodyText.localizedCaseInsensitiveContains("Failed to get client")
                let premiumRequired = http.statusCode == 403
                    && bodyText.localizedCaseInsensitiveContains("premium")
                if premiumRequired {
                    premiumRequiredBlocked = true
                    if !didLogPremiumRequired {
                        didLogPremiumRequired = true
                        Logger.library.warning(
                            "Spotify Dev Mode requires Premium on the app-owner account — falling back to MusicBrainz for ISRC."
                        )
                    }
                    return nil
                }
                if http.statusCode == 401 || http.statusCode == 403 || invalidClient {
                    credentialsRejected = true
                    if !didLogCredentialsRejected {
                        didLogCredentialsRejected = true
                        Logger.library.warning(
                            "Spotify credentials rejected (HTTP \(http.statusCode, privacy: .public)) body=\(bodyText.prefix(160), privacy: .public) — re-save Client ID/Secret from the Developer Dashboard."
                        )
                    }
                } else {
                    Logger.library.warning(
                        "Spotify token HTTP \(http.statusCode, privacy: .public) body=\(bodyText.prefix(160), privacy: .public)"
                    )
                }
                return nil
            }
            let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            accessToken = token.accessToken
            tokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
            Logger.library.debug("Spotify access token acquired (expires in \(token.expiresIn, privacy: .public)s)")
            return token.accessToken
        } catch {
            Logger.library.warning(
                "Spotify token request failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Legacy fallback — only used when Basic auth returns Spotify's "Failed to get client".
    private func fetchAccessTokenViaBodyCredentials() async -> String? {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type=client_credentials",
            "client_id=\(Self.formEncode(clientId))",
            "client_secret=\(Self.formEncode(clientSecret))",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            accessToken = token.accessToken
            tokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
            Logger.library.debug("Spotify access token acquired via body credentials fallback")
            return token.accessToken
        } catch {
            return nil
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+:@/?&=;$")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Trims whitespace and strips zero-width / BOM characters from pasted dashboard secrets.
    private static func sanitizeCredential(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x00A0: return false // ZW*, BOM, NBSP
            default: return true
            }
        }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authorizedGET(_ url: URL) async throws -> Data {
        try await authorizedGET(url, allowTokenRetry: true)
    }

    private func authorizedGET(_ url: URL, allowTokenRetry: Bool) async throws -> Data {
        guard let token = await validAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 401, allowTokenRetry {
            accessToken = nil
            tokenExpiresAt = .distantPast
            return try await authorizedGET(url, allowTokenRetry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyHTTPError.status(http.statusCode, body)
        }
        return data
    }

    private func fetchTrackISRC(id: String) async -> String? {
        guard let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else { return nil }
        do {
            let data = try await authorizedGET(url)
            let track = try JSONDecoder().decode(SpotifyTrackDetail.self, from: data)
            return track.externalIds?.isrc
        } catch {
            Logger.library.debug(
                "Spotify track detail failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Matching

    private static func searchQuery(title: String, artist: String?, album: String?) -> String {
        var parts: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append("track:\"\(t)\"") }
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("artist:\"\(artist.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        }
        if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("album:\"\(album.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        }
        if parts.isEmpty {
            return [title, artist, album]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return parts.joined(separator: " ")
    }

    private static func trackMatchScore(
        _ track: SpotifyTrack,
        title: String,
        artist: String?,
        album: String?
    ) -> Int {
        var score = 0
        if track.name.localizedCaseInsensitiveContains(title)
            || title.localizedCaseInsensitiveContains(track.name) {
            score += 4
        }
        if let artist,
           track.artists.contains(where: {
               $0.name.localizedCaseInsensitiveContains(artist)
                   || artist.localizedCaseInsensitiveContains($0.name)
           }) {
            score += 3
        }
        if let album,
           let albumName = track.album?.name,
           albumName.localizedCaseInsensitiveContains(album)
            || album.localizedCaseInsensitiveContains(albumName) {
            score += 2
        }
        return score
    }
}

// MARK: - DTOs
// `nonisolated` so Decodable conformances stay usable inside this actor under
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.

nonisolated private struct SpotifyTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

nonisolated private struct SpotifySearchResponse: Decodable, Sendable {
    let tracks: SpotifyTrackPage?
}

nonisolated private struct SpotifyTrackPage: Decodable, Sendable {
    let items: [SpotifyTrack]
}

nonisolated private struct SpotifyTrack: Decodable, Sendable {
    let id: String
    let name: String
    let artists: [SpotifyArtistRef]
    let album: SpotifyAlbumRef?
    let externalIds: SpotifyExternalIds?

    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case externalIds = "external_ids"
    }
}

nonisolated private struct SpotifyTrackDetail: Decodable, Sendable {
    let externalIds: SpotifyExternalIds?

    enum CodingKeys: String, CodingKey {
        case externalIds = "external_ids"
    }
}

nonisolated private struct SpotifyArtistRef: Decodable, Sendable {
    let name: String
}

nonisolated private struct SpotifyAlbumRef: Decodable, Sendable {
    let name: String
}

nonisolated private struct SpotifyExternalIds: Decodable, Sendable {
    let isrc: String?
}
