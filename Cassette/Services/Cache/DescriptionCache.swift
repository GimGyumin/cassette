// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CryptoKit
import Foundation
import OSLog

/// Persistent cache for album / artist descriptions fetched from
/// external sources (Wikipedia / MusicBrainz). Memory → disk under Caches.
///
/// Each entry stores `savedAt`. Fresh hits are returned as-is; stale hits are still
/// returned for instant UI, with `needsRefresh == true` so callers re-fetch.
actor DescriptionCache {
    static let shared = DescriptionCache()

    /// Default refresh window (30 days).
    static let defaultTTL: TimeInterval = 30 * 24 * 3600

    enum Kind: String, Sendable {
        case album
        case artist
    }

    enum Source: String, Codable, Sendable {
        /// Legacy Apple Music enrichment — treated like external for display.
        case appleMusic
        case external
    }

    struct Lookup: Sendable {
        let text: String
        let source: Source
        let savedAt: Date
        /// `true` when `savedAt` is older than the TTL — caller should re-fetch.
        let needsRefresh: Bool
    }

    private struct Entry: Codable, Sendable {
        let text: String
        let source: Source
        let savedAt: Date
    }

    private let ttl: TimeInterval
    private let cacheDirectory: URL
    private var memory: [String: Entry] = [:]

    init(ttl: TimeInterval = DescriptionCache.defaultTTL) {
        self.ttl = ttl
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("app.cassette/descriptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public

    /// Returns cached text when fresh; `nil` when missing or past TTL.
    func text(
        kind: Kind,
        name: String,
        artist: String? = nil,
        musicBrainzId: String? = nil
    ) -> String? {
        guard let hit = lookup(kind: kind, name: name, artist: artist, musicBrainzId: musicBrainzId),
              !hit.needsRefresh else { return nil }
        return hit.text
    }

    /// Returns a cache hit even when stale (for immediate display). Check `needsRefresh`.
    func lookup(
        kind: Kind,
        name: String,
        artist: String? = nil,
        musicBrainzId: String? = nil
    ) -> Lookup? {
        let key = makeKey(kind: kind, name: name, artist: artist, musicBrainzId: musicBrainzId)
        if let entry = memory[key] ?? readDisk(key: key) {
            memory[key] = entry
            return makeLookup(entry)
        }
        if kind == .album,
           let mbid = musicBrainzId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mbid.isEmpty {
            let mbidKey = "album|mbid:\(mbid.lowercased())"
            if let entry = memory[mbidKey] ?? readDisk(key: mbidKey) {
                memory[key] = entry
                return makeLookup(entry)
            }
        }
        return nil
    }

    func store(
        _ text: String,
        kind: Kind,
        name: String,
        artist: String? = nil,
        musicBrainzId: String? = nil,
        source: Source
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return }

        let entry = Entry(text: trimmed, source: source, savedAt: Date())
        let key = makeKey(kind: kind, name: name, artist: artist, musicBrainzId: musicBrainzId)
        memory[key] = entry
        writeDisk(key: key, entry: entry)

        if kind == .album,
           let mbid = musicBrainzId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mbid.isEmpty {
            let mbidKey = "album|mbid:\(mbid.lowercased())"
            memory[mbidKey] = entry
            writeDisk(key: mbidKey, entry: entry)
        }

        Logger.library.debug(
            "DescriptionCache store kind=\(kind.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) savedAt=\(entry.savedAt.timeIntervalSince1970, privacy: .public)"
        )
    }

    func clear() {
        memory.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    private func makeLookup(_ entry: Entry) -> Lookup {
        let age = Date().timeIntervalSince(entry.savedAt)
        let stale = age >= ttl
        if stale {
            Logger.library.debug(
                "DescriptionCache stale ageDays=\(Int(age / 86_400), privacy: .public) ttlDays=\(Int(self.ttl / 86_400), privacy: .public)"
            )
        }
        return Lookup(
            text: entry.text,
            source: entry.source,
            savedAt: entry.savedAt,
            needsRefresh: stale
        )
    }

    private func makeKey(
        kind: Kind,
        name: String,
        artist: String?,
        musicBrainzId: String?
    ) -> String {
        let n = Self.normalize(name)
        switch kind {
        case .album:
            return "album|\(n)|\(Self.normalize(artist ?? ""))"
        case .artist:
            return "artist|\(n)"
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private func diskURL(for key: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func readDisk(key: String) -> Entry? {
        let url = diskURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func writeDisk(key: String, entry: Entry) {
        let url = diskURL(for: key)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
