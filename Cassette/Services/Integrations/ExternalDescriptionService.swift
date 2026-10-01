// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// Structured MusicBrainz fields for the artist info page (origin / birthday).
nonisolated struct ArtistProfileFacts: Sendable, Equatable {
    var origin: String?
    var formattedBirthDate: String?
}

/// Fetches album / artist descriptions from free public sources
/// (Wikipedia REST summary → MusicBrainz Wikipedia link).
actor ExternalDescriptionService {
    static let shared = ExternalDescriptionService()

    private let session: URLSession
    private var albumCache: [String: String?] = [:]
    private var artistCache: [String: String?] = [:]
    private var labelCache: [String: String?] = [:]
    private var lastMBRequest: Date = .distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    /// Research notes for Song Info AI: song page → album → artist (Wikipedia / MusicBrainz).
    struct SongResearchContext: Sendable {
        var songExtract: String?
        var albumExtract: String?
        var artistExtract: String?

        var isEmpty: Bool {
            [songExtract, albumExtract, artistExtract]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .isEmpty
        }

        /// Compact source block for the language model (capped).
        var sourceBlock: String {
            var parts: [String] = []
            if let songExtract, !songExtract.isEmpty {
                parts.append("SONG RESEARCH:\n\(Self.clip(songExtract, max: 1_800))")
            }
            if let albumExtract, !albumExtract.isEmpty {
                parts.append("ALBUM RESEARCH:\n\(Self.clip(albumExtract, max: 1_400))")
            }
            if let artistExtract, !artistExtract.isEmpty {
                parts.append("ARTIST RESEARCH:\n\(Self.clip(artistExtract, max: 1_400))")
            }
            return parts.joined(separator: "\n\n")
        }

        private static func clip(_ text: String, max: Int) -> String {
            guard text.count > max else { return text }
            return String(text.prefix(max)) + "…"
        }
    }

    func researchSong(
        title: String,
        artistName: String?,
        albumName: String?
    ) async -> SongResearchContext {
        async let song = songDescription(title: title, artistName: artistName)
        async let album: String? = {
            guard let albumName, !albumName.isEmpty else { return nil }
            return await albumDescription(albumName: albumName, artistName: artistName)
        }()
        async let artist: String? = {
            guard let artistName, !artistName.isEmpty else { return nil }
            return await artistDescription(artistName: artistName)
        }()
        return SongResearchContext(
            songExtract: await song,
            albumExtract: await album,
            artistExtract: await artist
        )
    }

    func songDescription(title: String, artistName: String?) async -> String? {
        let key = "song|\(title)|\(artistName ?? "")".lowercased()
        if let cached = albumCache[key] { return cached } // reuse map; keyed distinctly

        for wikiTitle in Self.songWikipediaTitles(title: title, artist: artistName) {
            if let text = await wikipediaSummary(title: wikiTitle) {
                albumCache[key] = text
                return text
            }
        }

        if let text = await musicBrainzRecordingWikipedia(title: title, artistName: artistName) {
            albumCache[key] = text
            return text
        }

        albumCache[key] = nil
        return nil
    }

    /// Record label (phonogram copyright owner) resolved from MusicBrainz when the server
    /// didn't provide an OpenSubsonic `recordLabels` value. Free, no API key required.
    func albumRecordLabel(albumName: String, artistName: String?) async -> String? {
        let key = "label|\(albumName)|\(artistName ?? "")".lowercased()
        if let cached = labelCache[key] { return cached }

        guard let mbid = await resolveReleaseGroupMBID(
            albumName: albumName,
            artistName: artistName
        ) else {
            labelCache[key] = nil
            return nil
        }

        await enforceMBRateLimit()
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(mbid)&limit=1&inc=labels&fmt=json") else {
            labelCache[key] = nil
            return nil
        }
        do {
            let data = try await mbData(url: url)
            let decode = try JSONDecoder().decode(MBReleaseSearch.self, from: data)
            let label = decode.releases?
                .first?
                .labelInfo?
                .first?
                .label?
                .name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result = (label?.isEmpty == false) ? label : nil
            labelCache[key] = result
            return result
        } catch {
            Logger.library.debug(
                "MusicBrainz label resolve failed: \(error.localizedDescription, privacy: .public)"
            )
            labelCache[key] = nil
            return nil
        }
    }

    /// Resolve a release-group MBID from album + optional artist name (score-ranked).
    private func resolveReleaseGroupMBID(albumName: String, artistName: String?) async -> String? {
        await enforceMBRateLimit()
        var query = "releasegroup:\"\(albumName)\""
        if let artistName, !artistName.isEmpty {
            query += " AND artist:\"\(artistName)\""
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBReleaseGroupSearch.self, from: data)
            let groups = decoded.releaseGroups ?? []
            return (groups.first { ($0.score ?? 0) >= 80 } ?? groups.first)?.id
        } catch {
            Logger.library.debug(
                "MusicBrainz release-group search failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func albumDescription(
        albumName: String,
        artistName: String?,
        musicBrainzId: String? = nil
    ) async -> String? {
        let key = "\(albumName)|\(artistName ?? "")|\(musicBrainzId ?? "")".lowercased()
        if let cached = albumCache[key] { return cached }
        if let disk = await DescriptionCache.shared.lookup(
            kind: .album,
            name: albumName,
            artist: artistName,
            musicBrainzId: musicBrainzId
        ), !disk.needsRefresh {
            albumCache[key] = disk.text
            return disk.text
        } else {
            albumCache[key] = nil
        }

        if let mbid = musicBrainzId?.trimmingCharacters(in: .whitespacesAndNewlines), !mbid.isEmpty,
           let text = await wikipediaExtract(fromMusicBrainzAlbumID: mbid) {
            albumCache[key] = text
            await DescriptionCache.shared.store(
                text,
                kind: .album,
                name: albumName,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return text
        }

        for title in Self.albumWikipediaTitles(album: albumName, artist: artistName) {
            if let text = await wikipediaSummary(title: title) {
                albumCache[key] = text
                await DescriptionCache.shared.store(
                    text,
                    kind: .album,
                    name: albumName,
                    artist: artistName,
                    musicBrainzId: musicBrainzId,
                    source: .external
                )
                return text
            }
        }

        if let text = await musicBrainzReleaseGroupWikipedia(
            albumName: albumName,
            artistName: artistName
        ) {
            albumCache[key] = text
            await DescriptionCache.shared.store(
                text,
                kind: .album,
                name: albumName,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return text
        }

        albumCache[key] = nil
        return nil
    }

    func artistDescription(
        artistName: String,
        musicBrainzId: String? = nil
    ) async -> String? {
        let key = "\(artistName)|\(musicBrainzId ?? "")".lowercased()
        if let cached = artistCache[key] { return cached }
        if let disk = await DescriptionCache.shared.lookup(
            kind: .artist,
            name: artistName,
            musicBrainzId: musicBrainzId
        ), !disk.needsRefresh {
            artistCache[key] = disk.text
            return disk.text
        } else {
            artistCache[key] = nil
        }

        if let mbid = musicBrainzId?.trimmingCharacters(in: .whitespacesAndNewlines), !mbid.isEmpty,
           let text = await wikipediaExtract(fromMusicBrainzArtist: mbid) {
            artistCache[key] = text
            await DescriptionCache.shared.store(
                text,
                kind: .artist,
                name: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return text
        }

        for title in Self.artistWikipediaTitles(artist: artistName) {
            if let text = await wikipediaSummary(title: title) {
                artistCache[key] = text
                await DescriptionCache.shared.store(
                    text,
                    kind: .artist,
                    name: artistName,
                    musicBrainzId: musicBrainzId,
                    source: .external
                )
                return text
            }
        }

        if let text = await musicBrainzArtistWikipedia(artistName: artistName) {
            artistCache[key] = text
            await DescriptionCache.shared.store(
                text,
                kind: .artist,
                name: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return text
        }

        artistCache[key] = nil
        return nil
    }

    // MARK: - Artist profile facts (origin / birthday)

    private var profileCache: [String: ArtistProfileFacts] = [:]

    func artistProfileFacts(
        artistName: String,
        musicBrainzId: String?
    ) async -> ArtistProfileFacts {
        let key = "profile|\(artistName)|\(musicBrainzId ?? "")".lowercased()
        if let cached = profileCache[key] { return cached }

        var mbid = musicBrainzId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if mbid == nil || mbid?.isEmpty == true {
            mbid = await resolveArtistMBID(artistName: artistName)
        }
        guard let mbid, !mbid.isEmpty else {
            let empty = ArtistProfileFacts()
            profileCache[key] = empty
            return empty
        }

        let facts = await fetchArtistProfile(mbid: mbid)
        profileCache[key] = facts
        return facts
    }

    private func resolveArtistMBID(artistName: String) async -> String? {
        await enforceMBRateLimit()
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(artistName)\""),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBArtistSearch.self, from: data)
            let artists = decoded.artists ?? []
            let match = artists.first { ($0.score ?? 0) >= 80 } ?? artists.first
            return match?.id
        } catch {
            Logger.library.debug(
                "MB artist MBID resolve failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchArtistProfile(mbid: String) async -> ArtistProfileFacts {
        await enforceMBRateLimit()
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?fmt=json") else {
            return ArtistProfileFacts()
        }
        do {
            let data = try await mbData(url: url)
            let detail = try JSONDecoder().decode(MBArtistDetail.self, from: data)
            let origin = Self.preferredOrigin(area: detail.area, beginArea: detail.beginArea)
            // `life-span.begin` is a birthday for a Person, but a formation/debut date for a
            // Group/Band/Orchestra/etc. Only surface it as a birthday for persons (unknown type
            // defaults to person so solo artists without a type still show their birth date).
            let birthday: String?
            if detail.isGroup {
                birthday = nil
            } else {
                birthday = Self.formatLifeSpanBegin(detail.lifeSpan?.begin)
            }
            return ArtistProfileFacts(origin: origin, formattedBirthDate: birthday)
        } catch {
            Logger.library.debug(
                "MB artist profile failed: \(error.localizedDescription, privacy: .public)"
            )
            return ArtistProfileFacts()
        }
    }

    private static func preferredOrigin(area: MBArea?, beginArea: MBArea?) -> String? {
        // Prefer country / area of activity (Apple Music “Origin”), then birth place.
        if let name = area?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return Self.expandedCountryName(name)
        }
        if let name = beginArea?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return nil
    }

    private static func expandedCountryName(_ name: String) -> String {
        switch name {
        case "United States", "US", "USA":
            return "United States of America"
        case "United Kingdom", "UK", "GB":
            return "United Kingdom"
        default:
            return name
        }
    }

    private static func formatLifeSpanBegin(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap(Int.init) else { return raw }

        var components = DateComponents()
        components.year = year
        if parts.count >= 2, let month = Int(parts[1]) {
            components.month = month
        }
        if parts.count >= 3, let day = Int(parts[2]) {
            components.day = day
        }
        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            return raw
        }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if parts.count >= 3 {
            formatter.setLocalizedDateFormatFromTemplate("MMMMd yyyy")
        } else if parts.count == 2 {
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        return formatter.string(from: date)
    }

    // MARK: - Wikipedia

    private func wikipediaSummary(title: String) async -> String? {
        let encoded = title.replacingOccurrences(of: " ", with: "_")
        guard let path = encoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        for host in Self.wikipediaHosts {
            guard let url = URL(string: "https://\(host)/api/rest_v1/page/summary/\(path)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue("Cassette/1.0 (support@getcassette.app)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 12
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
                if decoded.type == "disambiguation" { continue }
                if let extract = Self.usableExtract(decoded.extract) {
                    Logger.library.debug(
                        "Wikipedia summary hit host=\(host, privacy: .public) title=\(title, privacy: .public)"
                    )
                    return extract
                }
            } catch {
                Logger.library.debug(
                    "Wikipedia summary failed host=\(host, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return nil
    }

    private static var wikipediaHosts: [String] {
        var hosts: [String] = []
        // Prefer the app/device UI language (per-app language setting included).
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        let lang = preferred.split(separator: "-").first.map(String.init)
            ?? Locale.current.language.languageCode?.identifier
        if let lang, lang != "en" {
            hosts.append("\(lang).wikipedia.org")
        }
        hosts.append("en.wikipedia.org")
        return hosts
    }

    private static func songWikipediaTitles(title: String, artist: String?) -> [String] {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        var titles: [String] = []
        if let artist, !artist.isEmpty {
            titles.append("\(cleaned) (\(artist) song)")
            titles.append("\(cleaned) (\(artist))")
            titles.append("\(cleaned) (\(artist)의 노래)")
            titles.append("\(artist)의 \(cleaned)")
        }
        titles.append("\(cleaned) (song)")
        titles.append("\(cleaned) (노래)")
        titles.append(cleaned)
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return titles.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func albumWikipediaTitles(album: String, artist: String?) -> [String] {
        let cleaned = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        var titles: [String] = []
        if let artist, !artist.isEmpty {
            titles.append("\(cleaned) (\(artist) album)")
            titles.append("\(cleaned) (\(artist))")
        }
        titles.append("\(cleaned) (album)")
        titles.append(cleaned)
        return titles
    }

    private static func artistWikipediaTitles(artist: String) -> [String] {
        let cleaned = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return [
            "\(cleaned) (band)",
            "\(cleaned) (musician)",
            "\(cleaned) (singer)",
            cleaned,
        ]
    }

    private static func usableExtract(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80 else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("may refer to") || lowered.contains("may refer to:") { return nil }
        return text
    }

    // MARK: - MusicBrainz → Wikipedia

    private func musicBrainzRecordingWikipedia(
        title: String,
        artistName: String?
    ) async -> String? {
        await enforceMBRateLimit()
        var query = "recording:\"\(title)\""
        if let artistName, !artistName.isEmpty {
            query += " AND artist:\"\(artistName)\""
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBRecordingSearch.self, from: data)
            let recordings = decoded.recordings ?? []
            let match = recordings.first { ($0.score ?? 0) >= 80 } ?? recordings.first
            guard let mbid = match?.id else { return nil }
            return await wikipediaExtract(fromMBEntityPath: "recording/\(mbid)")
        } catch {
            Logger.library.debug(
                "MusicBrainz recording search failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func musicBrainzReleaseGroupWikipedia(
        albumName: String,
        artistName: String?
    ) async -> String? {
        guard let mbid = await resolveReleaseGroupMBID(albumName: albumName, artistName: artistName) else {
            return nil
        }
        return await wikipediaExtract(fromMusicBrainzAlbumID: mbid)
    }

    private func musicBrainzArtistWikipedia(artistName: String) async -> String? {
        await enforceMBRateLimit()
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(artistName)\""),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBArtistSearch.self, from: data)
            let artists = decoded.artists ?? []
            let match = artists.first { ($0.score ?? 0) >= 80 } ?? artists.first
            guard let mbid = match?.id else { return nil }
            return await wikipediaExtract(fromMusicBrainzArtist: mbid)
        } catch {
            Logger.library.debug(
                "MB artist search failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Subsonic `AlbumInfo.musicBrainzId` may be a release-group or a release MBID.
    private func wikipediaExtract(fromMusicBrainzAlbumID mbid: String) async -> String? {
        if let text = await wikipediaExtract(fromMBEntityPath: "release-group/\(mbid)") {
            return text
        }
        // Release MBIDs: read release url-rels, then follow the linked release-group.
        await enforceMBRateLimit()
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/\(mbid)?inc=url-rels+release-groups&fmt=json") else {
            return nil
        }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBReleaseDetail.self, from: data)
            if let text = await wikipediaExtract(fromRelations: decoded.relations) {
                return text
            }
            if let rgid = decoded.releaseGroup?.id {
                return await wikipediaExtract(fromMBEntityPath: "release-group/\(rgid)")
            }
        } catch {
            return nil
        }
        return nil
    }

    private func wikipediaExtract(fromMBEntityPath path: String) async -> String? {
        await enforceMBRateLimit()
        guard let url = URL(string: "https://musicbrainz.org/ws/2/\(path)?inc=url-rels&fmt=json") else {
            return nil
        }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBEntityWithRelations.self, from: data)
            return await wikipediaExtract(fromRelations: decoded.relations)
        } catch {
            return nil
        }
    }

    private func wikipediaExtract(fromMusicBrainzArtist mbid: String) async -> String? {
        await enforceMBRateLimit()
        guard let url = URL(string: "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json") else {
            return nil
        }
        do {
            let data = try await mbData(url: url)
            let decoded = try JSONDecoder().decode(MBEntityWithRelations.self, from: data)
            return await wikipediaExtract(fromRelations: decoded.relations)
        } catch {
            return nil
        }
    }

    private func wikipediaExtract(fromRelations relations: [MBURLRelation]?) async -> String? {
        guard let relations else { return nil }
        // Prefer Wikipedia page titles; fall back through Wikidata sitelinks.
        for rel in relations where rel.type == "wikipedia" {
            if let resource = rel.url?.resource,
               let title = Self.wikipediaTitle(from: resource),
               let text = await wikipediaSummary(title: title) {
                return text
            }
        }
        for rel in relations where rel.type == "wikidata" {
            if let resource = rel.url?.resource,
               let qid = resource.components(separatedBy: "/").last,
               qid.hasPrefix("Q"),
               let text = await wikipediaExtract(fromWikidata: qid) {
                return text
            }
        }
        return nil
    }

    private func wikipediaExtract(fromWikidata qid: String) async -> String? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"),
            URLQueryItem(name: "ids", value: qid),
            URLQueryItem(name: "props", value: "sitelinks"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Cassette/1.0 (support@getcassette.app)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 12
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(WikidataSitelinksResponse.self, from: data)
            let sitelinks = decoded.entities[qid]?.sitelinks ?? [:]
            let preferredKeys: [String] = {
                var keys: [String] = []
                if let lang = Locale.current.language.languageCode?.identifier {
                    keys.append("\(lang)wiki")
                }
                keys.append("enwiki")
                return keys
            }()
            for key in preferredKeys {
                if let title = sitelinks[key]?.title,
                   let text = await wikipediaSummary(title: title) {
                    return text
                }
            }
        } catch {
            Logger.library.debug(
                "Wikidata sitelinks failed for \(qid, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    private static func wikipediaTitle(from resource: String) -> String? {
        // https://en.wikipedia.org/wiki/Thriller_(Michael_Jackson_album)
        guard let url = URL(string: resource),
              url.host?.contains("wikipedia.org") == true else { return nil }
        let last = url.pathComponents.last ?? ""
        guard !last.isEmpty, last != "/" else { return nil }
        return last.removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
    }

    private func mbData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Cassette/1.0 (support@getcassette.app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func enforceMBRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastMBRequest)
        if elapsed < 1.05 {
            try? await Task.sleep(for: .seconds(1.05 - elapsed))
        }
        lastMBRequest = Date()
    }
}

// MARK: - Models
// `nonisolated` so Decodable conformances stay usable inside this actor under
// Swift 6 default MainActor isolation.

nonisolated private struct WikipediaSummary: Decodable, Sendable {
    let type: String?
    let extract: String?
}

nonisolated private struct MBRecordingSearch: Decodable, Sendable {
    let recordings: [MBScoredEntity]?
}

nonisolated private struct MBReleaseGroupSearch: Decodable, Sendable {
    let releaseGroups: [MBScoredEntity]?
    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

nonisolated private struct MBReleaseSearch: Decodable, Sendable {
    let releases: [MBRelease]?
}

nonisolated private struct MBRelease: Decodable, Sendable {
    let labelInfo: [MBLabelInfo]?
    enum CodingKeys: String, CodingKey {
        case labelInfo = "label-info"
    }
}

nonisolated private struct MBLabelInfo: Decodable, Sendable {
    let label: MBLabel?
}

nonisolated private struct MBLabel: Decodable, Sendable {
    let name: String?
}

nonisolated private struct MBArtistSearch: Decodable, Sendable {
    let artists: [MBScoredEntity]?
}

nonisolated private struct MBScoredEntity: Decodable, Sendable {
    let id: String
    let score: Int?
}

nonisolated private struct MBArtistDetail: Decodable, Sendable {
    let type: String?
    let area: MBArea?
    let beginArea: MBArea?
    let lifeSpan: MBLifeSpan?

    enum CodingKeys: String, CodingKey {
        case type
        case area
        case beginArea = "begin-area"
        case lifeSpan = "life-span"
    }

    /// MusicBrainz marks groups/bands/orchestras with a non-person `type`; their
    /// `life-span.begin` is a formation date, not a birthday.
    var isGroup: Bool {
        switch type?.lowercased() {
        case "group", "band", "orchestra", "choir", "ensemble", "character", "other":
            return true
        case "person", "", .none:
            return false
        default:
            return false
        }
    }
}

nonisolated private struct MBArea: Decodable, Sendable {
    let name: String?
    let type: String?
}

nonisolated private struct MBLifeSpan: Decodable, Sendable {
    let begin: String?
    let end: String?
}

nonisolated private struct MBEntityWithRelations: Decodable, Sendable {
    let relations: [MBURLRelation]?
}

nonisolated private struct MBReleaseDetail: Decodable, Sendable {
    let relations: [MBURLRelation]?
    let releaseGroup: MBScoredEntity?
    enum CodingKeys: String, CodingKey {
        case relations
        case releaseGroup = "release-group"
    }
}

nonisolated private struct MBURLRelation: Decodable, Sendable {
    let type: String
    let url: MBURLResource?
}

nonisolated private struct MBURLResource: Decodable, Sendable {
    let resource: String
}

nonisolated private struct WikidataSitelinksResponse: Decodable, Sendable {
    let entities: [String: WikidataEntity]
}

nonisolated private struct WikidataEntity: Decodable, Sendable {
    let sitelinks: [String: WikidataSitelink]?
}

nonisolated private struct WikidataSitelink: Decodable, Sendable {
    let title: String
}
