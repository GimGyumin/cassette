// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// Matches library tracks to the Apple Music catalog for ISRC (Music Haptics / Now Playing).
/// Uses a developer media token (JWT) from Settings — no MusicKit user auth required for catalog search.
actor AppleMusicCatalogService {
    static let shared = AppleMusicCatalogService()

    private let session: URLSession
    private var isrcCache: [String: String] = [:]
    private var editorialCache: [String: String] = [:]
    private var developerToken: String = ""
    private var storefront: String = ""
    /// After 401/403, skip further Apple Music calls until the token changes.
    private var authRejected = false
    private var loggedAuthRejection = false

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setCredentials(developerToken: String, storefront: String) {
        let token = Self.sanitize(developerToken)
        let sf = Self.sanitizeStorefront(storefront)
        let changed = token != self.developerToken || sf != self.storefront
        self.developerToken = token
        self.storefront = sf
        if changed {
            isrcCache.removeAll(keepingCapacity: true)
            editorialCache.removeAll(keepingCapacity: true)
            authRejected = false
            loggedAuthRejection = false
        }
    }

    /// Best-effort album About text from Apple Music Catalog `editorialNotes`.
    func albumEditorialNotes(albumName: String, artistName: String?) async -> String? {
        let key = "notes|\(albumName)|\(artistName ?? "")".lowercased()
        if let cached = editorialCache[key] { return cached }

        guard await ensureCredentialsLoaded() else {
            Logger.library.debug("Apple Music editorialNotes skipped — developer token not set")
            return nil
        }
        if authRejected { return nil }

        let term = Self.searchTerm(title: albumName, artist: artistName, album: nil)
        guard !term.isEmpty else { return nil }

        let sf = resolvedStorefront()
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(sf)/search")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                handleHTTPFailure(status: http.statusCode, body: data)
                return nil
            }
            let decoded = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: data)
            let albums = decoded.results?.albums?.data ?? []
            let ranked = albums.sorted {
                Self.albumMatchScore($0, albumName: albumName, artistName: artistName)
                    > Self.albumMatchScore($1, albumName: albumName, artistName: artistName)
            }
            for album in ranked {
                if let notes = album.attributes?.editorialNotes?.preferredText {
                    editorialCache[key] = notes
                    Logger.library.debug(
                        "Apple Music editorialNotes ok album=\(album.attributes?.name ?? "", privacy: .public)"
                    )
                    return notes
                }
            }
            Logger.library.debug(
                "Apple Music editorialNotes: no notes in \(albums.count, privacy: .public) hit(s) for \(albumName, privacy: .public)"
            )
        } catch is CancellationError {
        } catch {
            Logger.library.warning(
                "Apple Music editorialNotes failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    /// Best-effort ISRC from Apple Music Catalog Search API.
    func catalogISRC(title: String, artist: String?, album: String?) async -> String? {
        let key = "isrc|\(title)|\(artist ?? "")|\(album ?? "")".lowercased()
        if let cached = isrcCache[key] { return cached }

        guard await ensureCredentialsLoaded() else {
            Logger.library.debug("Apple Music ISRC skipped — developer token not set")
            return nil
        }
        if authRejected {
            return nil
        }

        let term = Self.searchTerm(title: title, artist: artist, album: album)
        guard !term.isEmpty else { return nil }

        let sf = resolvedStorefront()
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(sf)/search")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                handleHTTPFailure(status: http.statusCode, body: data)
                return nil
            }
            let decoded = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: data)
            let songs = decoded.results?.songs?.data ?? []
            let ranked = songs.sorted {
                Self.matchScore($0, title: title, artist: artist, album: album)
                    > Self.matchScore($1, title: title, artist: artist, album: album)
            }
            for song in ranked {
                if let isrc = song.attributes?.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !isrc.isEmpty {
                    isrcCache[key] = isrc
                    Logger.library.debug(
                        "Apple Music ISRC ok isrc=\(isrc, privacy: .public) title=\(song.attributes?.name ?? "", privacy: .public)"
                    )
                    return isrc
                }
            }
            Logger.library.debug(
                "Apple Music ISRC: no ISRC in \(songs.count, privacy: .public) hit(s) for \(title, privacy: .public)"
            )
        } catch is CancellationError {
            // Navigation / track change — ignore.
        } catch {
            Logger.library.warning(
                "Apple Music ISRC lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    // MARK: - Credentials

    private func handleHTTPFailure(status: Int, body: Data) {
        let snippet = String(data: body, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(160) ?? ""
        if status == 401 || status == 403 {
            authRejected = true
            if !loggedAuthRejection {
                loggedAuthRejection = true
                Logger.library.error(
                    "Apple Music developer token rejected (HTTP \(status, privacy: .public)). Replace the MusicKit JWT in Account. Falling back to MusicBrainz until then. \(snippet, privacy: .public)"
                )
            }
            return
        }
        Logger.library.warning(
            "Apple Music ISRC HTTP \(status, privacy: .public): \(snippet, privacy: .public)"
        )
    }

    private func ensureCredentialsLoaded() async -> Bool {
        let token = Self.sanitize(
            SensitiveSettingsStore.string(forKey: AppleMusicSettings.appleMusicDeveloperTokenKey) ?? ""
        )
        let sf = Self.sanitizeStorefront(
            UserDefaults.standard.string(forKey: AppleMusicSettings.appleMusicStorefrontKey) ?? ""
        )
        if token != developerToken || sf != storefront {
            setCredentials(developerToken: token, storefront: sf)
        }
        return !developerToken.isEmpty
    }

    private func resolvedStorefront() -> String {
        if !storefront.isEmpty { return storefront }
        return (Locale.current.region?.identifier ?? "us").lowercased()
    }

    private static func sanitize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    private static func sanitizeStorefront(_ raw: String) -> String {
        sanitize(raw).lowercased()
    }

    private static func searchTerm(title: String, artist: String?, album: String?) -> String {
        [title, artist, album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func matchScore(
        _ song: AppleMusicSong,
        title: String,
        artist: String?,
        album: String?
    ) -> Int {
        var score = 0
        let name = song.attributes?.name ?? ""
        if name.caseInsensitiveCompare(title) == .orderedSame { score += 8 }
        else if name.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(name) {
            score += 4
        }
        if let artist,
           let artists = song.attributes?.artistName,
           artists.localizedCaseInsensitiveContains(artist) {
            score += 4
        }
        if let album,
           let albumName = song.attributes?.albumName,
           albumName.localizedCaseInsensitiveContains(album) {
            score += 2
        }
        if song.attributes?.isrc?.isEmpty == false { score += 1 }
        return score
    }

    private static func albumMatchScore(
        _ album: AppleMusicAlbum,
        albumName: String,
        artistName: String?
    ) -> Int {
        var score = 0
        let name = album.attributes?.name ?? ""
        if name.caseInsensitiveCompare(albumName) == .orderedSame { score += 8 }
        else if name.localizedCaseInsensitiveContains(albumName)
            || albumName.localizedCaseInsensitiveContains(name) {
            score += 4
        }
        if let artistName,
           let artists = album.attributes?.artistName,
           artists.localizedCaseInsensitiveContains(artistName) {
            score += 4
        }
        if album.attributes?.editorialNotes?.preferredText != nil { score += 2 }
        return score
    }
}

// MARK: - DTOs

nonisolated private struct AppleMusicSearchResponse: Decodable, Sendable {
    let results: AppleMusicSearchResults?
}

nonisolated private struct AppleMusicSearchResults: Decodable, Sendable {
    let songs: AppleMusicSongList?
    let albums: AppleMusicAlbumList?
}

nonisolated private struct AppleMusicSongList: Decodable, Sendable {
    let data: [AppleMusicSong]?
}

nonisolated private struct AppleMusicAlbumList: Decodable, Sendable {
    let data: [AppleMusicAlbum]?
}

nonisolated private struct AppleMusicSong: Decodable, Sendable {
    let id: String?
    let attributes: AppleMusicSongAttributes?
}

nonisolated private struct AppleMusicSongAttributes: Decodable, Sendable {
    let name: String?
    let artistName: String?
    let albumName: String?
    let isrc: String?
}

nonisolated private struct AppleMusicAlbum: Decodable, Sendable {
    let id: String?
    let attributes: AppleMusicAlbumAttributes?
}

nonisolated private struct AppleMusicAlbumAttributes: Decodable, Sendable {
    let name: String?
    let artistName: String?
    let editorialNotes: AppleMusicEditorialNotes?
}

nonisolated private struct AppleMusicEditorialNotes: Decodable, Sendable {
    let standard: String?
    let short: String?

    var preferredText: String? {
        let candidates = [standard, short]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first
    }
}
