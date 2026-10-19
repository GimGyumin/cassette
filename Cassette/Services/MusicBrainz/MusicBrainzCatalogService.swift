// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

/// ISRC lookup via MusicBrainz (no Spotify credentials required).
actor MusicBrainzCatalogService {
    static let shared = MusicBrainzCatalogService()

    private let session: URLSession
    private var isrcCache: [String: String] = [:]
    private var nextRequestAt: Date = .distantPast
    private var blockedUntil: Date = .distantPast
    private var lookupCooldown: [String: Date] = [:]
    private let requestInterval: TimeInterval
    private let retryBaseDelay: TimeInterval

    init(session: URLSession? = nil, requestInterval: TimeInterval = 1.1, retryBaseDelay: TimeInterval = 0.8) {
        self.requestInterval = requestInterval
        self.retryBaseDelay = retryBaseDelay
        // Dedicated session — avoids sharing a flaky connection pool with other hosts.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            config.httpAdditionalHeaders = [
                "User-Agent": "Cassette/1.0 (support@getcassette.app)",
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    func catalogISRC(title: String, artist: String?, album: String?) async -> String? {
        let key = "isrc|\(title)|\(artist ?? "")|\(album ?? "")".lowercased()
        if let cached = isrcCache[key] { return cached }
        if let until = lookupCooldown[key], Date() < until { return nil }

        let titleQ = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleQ.isEmpty else { return nil }

        // Tight query first, then looser (no album) if empty/failed.
        let queries: [String] = {
            var list: [String] = []
            var tight: [String] = ["recording:\"\(Self.escape(titleQ))\""]
            if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tight.append("artist:\"\(Self.escape(artist.trimmingCharacters(in: .whitespacesAndNewlines)))\"")
            }
            if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var withAlbum = tight
                withAlbum.append("release:\"\(Self.escape(album.trimmingCharacters(in: .whitespacesAndNewlines)))\"")
                list.append(withAlbum.joined(separator: " AND "))
            }
            list.append(tight.joined(separator: " AND "))
            return list
        }()

        do {
            for query in queries {
                if let isrc = try await searchISRC(query: query, title: titleQ, artist: artist) {
                    isrcCache[key] = isrc
                    return isrc
                }
            }
        } catch {
            guard !Task.isCancelled, PlaybackFailure.classify(error).kind != .cancelled else { return nil }
            Logger.library.warning("MusicBrainz ISRC lookup failed: \(String(describing: error), privacy: .public)")
        }
        lookupCooldown = lookupCooldown.filter { $0.value > Date() }
        if lookupCooldown.count >= 256 { lookupCooldown.removeAll(keepingCapacity: true) }
        lookupCooldown[key] = max(Date().addingTimeInterval(60), blockedUntil)
        return nil
    }

    private func searchISRC(query: String, title: String, artist: String?) async throws -> String? {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url else { return nil }

        let data = try await getWithRetry(url)
        let page = try JSONDecoder().decode(MBRecordingSearch.self, from: data)
        let ranked = (page.recordings ?? []).sorted {
            Self.score($0, title: title, artist: artist) > Self.score($1, title: title, artist: artist)
        }
        for recording in ranked {
            if let isrc = recording.isrcs?.first(where: { !$0.isEmpty }) {
                Logger.library.debug(
                    "MusicBrainz ISRC ok isrc=\(isrc, privacy: .public) title=\(recording.title ?? "", privacy: .public)"
                )
                return isrc
            }
            if let id = recording.id, let isrc = try await fetchISRCs(recordingID: id).first {
                Logger.library.debug(
                    "MusicBrainz ISRC ok (detail) isrc=\(isrc, privacy: .public) id=\(id, privacy: .public)"
                )
                return isrc
            }
        }
        return nil
    }

    private func fetchISRCs(recordingID: String) async throws -> [String] {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/\(recordingID)?inc=isrcs&fmt=json") else {
            return []
        }
        let data = try await getWithRetry(url)
        let detail = try JSONDecoder().decode(MBRecordingDetail.self, from: data)
        return detail.isrcs ?? []
    }

    private func getWithRetry(_ url: URL) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await throttle()
                return try await get(url)
            } catch {
                lastError = error
                if Task.isCancelled || PlaybackFailure.classify(error).kind == .cancelled { throw CancellationError() }
                let ns = error as NSError
                let http = error as? HTTPTransferFailure
                let retryable = http.map { $0.statusCode == 429 || (500...599).contains($0.statusCode) } ?? (ns.domain == NSURLErrorDomain
                    && [
                        NSURLErrorTimedOut,
                        NSURLErrorNetworkConnectionLost,
                        NSURLErrorNotConnectedToInternet,
                        NSURLErrorCannotConnectToHost,
                        NSURLErrorSecureConnectionFailed, // -1200 TLS
                        NSURLErrorCannotLoadFromNetwork,
                    ].contains(ns.code))
                let delay = max(retryBaseDelay * pow(2, Double(attempt)), http?.retryAfter ?? 0)
                if retryable { blockedUntil = max(blockedUntil, Date().addingTimeInterval(delay)) }
                guard retryable, attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Cassette/1.0 (support@getcassette.app)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPTransferFailure(response: response, stage: "MusicBrainz lookup")
        }
        return data
    }

    private func throttle() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            let readyAt = max(nextRequestAt, blockedUntil)
            if readyAt <= now {
                nextRequestAt = now.addingTimeInterval(requestInterval)
                return
            }
            try await Task.sleep(for: .seconds(readyAt.timeIntervalSince(now)))
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func score(_ recording: MBRecording, title: String, artist: String?) -> Int {
        var score = 0
        if let t = recording.title {
            if t.localizedCaseInsensitiveCompare(title) == .orderedSame { score += 5 }
            else if t.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains(t) {
                score += 3
            }
        }
        if let artist,
           recording.artistCredit?.contains(where: {
               ($0.name ?? "").localizedCaseInsensitiveContains(artist)
                   || artist.localizedCaseInsensitiveContains($0.name ?? "")
           }) == true {
            score += 3
        }
        if recording.isrcs?.isEmpty == false { score += 2 }
        return score
    }
}

// MARK: - DTOs
// `nonisolated` so Decodable conformances stay usable inside this actor under
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.

nonisolated private struct MBRecordingSearch: Decodable, Sendable {
    let recordings: [MBRecording]?
}

nonisolated private struct MBRecording: Decodable, Sendable {
    let id: String?
    let title: String?
    let isrcs: [String]?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, isrcs
        case artistCredit = "artist-credit"
    }
}

nonisolated private struct MBArtistCredit: Decodable, Sendable {
    let name: String?
}

nonisolated private struct MBRecordingDetail: Decodable, Sendable {
    let isrcs: [String]?
}
