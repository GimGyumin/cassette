import Foundation
import SwiftSonic

/// Display grouping only. Server IDs and server-owned album contents remain intact.
nonisolated enum AtmosAlbumPolicy {
    static func baseName(_ name: String) -> String {
        name.replacingOccurrences(of: #"(?i)\s*\(Dolby Atmos\)\s*$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAtmos(_ name: String?) -> Bool {
        guard let name else { return false }
        // Dedicated collections (e.g. "Michael Jackson's The Dolby Atmos") need
        // not be an album's parenthesized edition. Only baseName controls merging.
        return name.range(of: #"\bdolby\s+atmos\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func hasSameArtist(_ first: AlbumID3, _ second: AlbumID3) -> Bool {
        guard let firstKey = artistKey(first), firstKey == artistKey(second) else { return false }
        if let a = first.artistId, let b = second.artistId, !a.isEmpty, !b.isEmpty, a != b { return false }
        return true
    }

    static func normalized(_ value: String) -> String {
        // Do not strip diacritics or punctuation: similar names are not identity evidence.
        value.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func artistKey(_ album: AlbumID3) -> String? {
        if let artists = album.artists, !artists.isEmpty {
            let names = artists.map { normalized($0.name) }.sorted()
            guard names.allSatisfy({ !$0.isEmpty }) else { return nil }
            return names.joined(separator: "\u{1f}")
        }
        let name = normalized(album.artist ?? "")
        return name.isEmpty ? nil : name
    }

    static func pairKey(_ album: AlbumID3) -> String? {
        guard let artist = artistKey(album) else { return nil }
        let name = normalized(baseName(album.name))
        return name.isEmpty ? nil : artist + "\u{1e}" + name
    }

    static func pairs(in albums: [AlbumID3]) -> [String: String] {
        let originals = Dictionary(grouping: albums.filter { !isAtmos($0.name) }, by: { pairKey($0) })
        var result: [String: String] = [:]
        for album in albums where isAtmos(album.name) {
            guard let key = pairKey(album), let bases = originals[key], bases.count == 1 else { continue }
            let base = bases[0]
            // Distinct supplied primary artist IDs are a conflict, even for identical names.
            if let a = album.artistId, let b = base.artistId, !a.isEmpty, !b.isEmpty, a != b { continue }
            result[album.id] = base.id
        }
        return result
    }

    static func presented(_ albums: [AlbumID3], catalog: [AlbumID3] = []) -> [AlbumID3] {
        let all = Dictionary((catalog + albums).map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
        let pairs = pairs(in: Array(all.values))
        var seen = Set<String>()
        return albums.compactMap { album in
            let primary = pairs[album.id].flatMap { all[$0] } ?? album
            return seen.insert(primary.id).inserted ? primary : nil
        }
    }

    static func combining(_ base: AlbumID3, songs: [Song]) -> AlbumID3 {
        let originalIDs = Set((base.song ?? []).map(\.id))
        let extraDuration = songs.filter { !originalIDs.contains($0.id) }.reduce(0) {
            let (total, overflow) = $0.addingReportingOverflow(max(0, $1.duration ?? 0))
            return overflow ? Int.max : total
        }
        let (totalDuration, overflow) = max(0, base.duration).addingReportingOverflow(extraDuration)
        return AlbumID3(id: base.id, name: base.name, songCount: songs.count,
                 duration: overflow ? Int.max : totalDuration,
                 artist: base.artist, artistId: base.artistId, coverArt: base.coverArt,
                 playCount: base.playCount, created: base.created, starred: base.starred,
                 year: base.year, genre: base.genre, played: base.played, userRating: base.userRating,
                 musicBrainzId: base.musicBrainzId, genres: base.genres, artists: base.artists,
                 displayArtist: base.displayArtist, releaseTypes: base.releaseTypes, moods: base.moods,
                 sortName: base.sortName, originalReleaseDate: base.originalReleaseDate,
                 releaseDate: base.releaseDate, isCompilation: base.isCompilation, discTitles: base.discTitles,
                 recordLabels: base.recordLabels, explicitStatus: base.explicitStatus, version: base.version, song: songs)
    }
}

/// A title/artist bucket keeps both building and lookup independent of library size.
/// This intentionally strips only the delivery-format suffix, never Live/Remix/Edit tags.
nonisolated struct AtmosVariantCatalogue: Sendable {
    let albums: [AlbumID3]
    private let albumsByID: [String: AlbumID3]
    let albumPairs: [String: String]
    let songsByID: [String: DisplayableSong]
    private let buckets: [String: [DisplayableSong]]
    let matches: [String: String]
    static let matchingVersion = 2

    func coverArtID(forAlbumID id: String?) -> String? {
        guard let id, let value = albumsByID[id]?.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    init(songs: [DisplayableSong] = [], albums: [AlbumID3] = [], storedMatches: [String: String]? = nil) {
        self.albums = albums
        albumsByID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
        albumPairs = AtmosAlbumPolicy.pairs(in: albums)
        let indexedSongs = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
        songsByID = indexedSongs
        buckets = Dictionary(grouping: songs.filter(Self.isAtmos), by: Self.key)
        if let storedMatches {
            self.matches = storedMatches.filter { originalID, candidateID in
                guard let original = indexedSongs[originalID], let candidate = indexedSongs[candidateID] else { return false }
                return Self.compatible(original, candidate)
            }
        } else {
            var matches: [String: String] = [:]
            for song in songs where !Self.isAtmos(song) {
                if let candidate = Self.select(for: song, among: buckets[Self.key(song)] ?? [], pairs: albumPairs) {
                    matches[song.id] = candidate.id
                }
            }
            self.matches = matches
        }
    }

    static func isAtmos(_ song: DisplayableSong) -> Bool {
        song.isOriginalAudio != false && AtmosAlbumPolicy.isAtmos(song.albumName)
    }

    static func key(_ song: DisplayableSong) -> String {
        AtmosAlbumPolicy.normalized(song.artist ?? "") + "\u{1e}" + AtmosAlbumPolicy.normalized(AtmosAlbumPolicy.baseName(song.title))
    }

    static func compatible(_ original: DisplayableSong, _ candidate: DisplayableSong) -> Bool {
        guard original.id != candidate.id, isAtmos(candidate), key(original) == key(candidate),
              !AtmosAlbumPolicy.normalized(original.artist ?? "").isEmpty,
              !AtmosAlbumPolicy.normalized(AtmosAlbumPolicy.baseName(original.title)).isEmpty else { return false }
        if let a = original.artistId, let b = candidate.artistId, !a.isEmpty, !b.isEmpty, a != b { return false }
        if recordingContext(original) != recordingContext(candidate) { return false }
        let a = original.musicBrainzRecordingID?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = candidate.musicBrainzRecordingID?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !a.isEmpty, !b.isEmpty, a != b { return false }
        // Clean and explicit cuts must not be silently exchanged.
        if let a = original.explicitStatus, let b = candidate.explicitStatus, a != b { return false }
        guard original.duration.isFinite, candidate.duration.isFinite,
              original.duration > 0, candidate.duration > 0,
              abs(original.duration - candidate.duration) <= 2 else { return false }
        return true
    }

    private static func recordingContext(_ song: DisplayableSong) -> Set<String> {
        let album = AtmosAlbumPolicy.normalized(AtmosAlbumPolicy.baseName(song.albumName ?? ""))
        var context = Set<String>()
        if album.range(of: #"\blive\s+(at|in|from|on)\b|[\[(]\s*live\b|^live$|\s-\s*live$"#, options: .regularExpression) != nil { context.insert("live") }
        if album.range(of: #"\b(remixes|remix album|instrumental|karaoke)\b"#, options: .regularExpression) != nil { context.insert("alternate") }
        return context
    }

    func presented(_ values: [AlbumID3]) -> [AlbumID3] {
        // Fold incoming-only pairs too, while reusing the installed O(1) catalog map.
        let incoming = AtmosAlbumPolicy.presented(values)
        var seen = Set<String>()
        return incoming.compactMap { album in
            let base = albumPairs[album.id].flatMap { albumsByID[$0] } ?? album
            return seen.insert(base.id).inserted ? base : nil
        }
    }

    private static func select(for song: DisplayableSong, among candidates: [DisplayableSong], pairs: [String: String]) -> DisplayableSong? {
        var candidates = candidates.filter { compatible(song, $0) }
        let sameAlbum = candidates.filter { candidate in
            guard let album = candidate.albumId, let base = song.albumId else { return false }
            return pairs[album] == base
        }
        if !sameAlbum.isEmpty { candidates = sameAlbum }
        let mbid = song.musicBrainzRecordingID?.lowercased() ?? ""
        let exact = candidates.filter { !mbid.isEmpty && $0.musicBrainzRecordingID?.lowercased() == mbid }
        if !exact.isEmpty { candidates = exact }
        // Equal evidence is ambiguous; do not choose a random compilation or remix.
        return candidates.count == 1 ? candidates[0] : nil
    }

    func preferred(for song: DisplayableSong) -> DisplayableSong? {
        if Self.isAtmos(song) { return nil }
        if songsByID[song.id] == song, let id = matches[song.id] { return songsByID[id] }
        return Self.select(for: song, among: buckets[Self.key(song)] ?? [], pairs: albumPairs)
    }

    func manualCandidates(for song: DisplayableSong) -> [DisplayableSong] {
        let artist = AtmosAlbumPolicy.normalized(song.artist ?? "")
        guard !artist.isEmpty else { return [] }
        return songsByID.values.filter {
            Self.isAtmos($0) && $0.id != song.id && AtmosAlbumPolicy.normalized($0.artist ?? "") == artist
        }.sorted {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if $0.albumName != $1.albumName { return ($0.albumName ?? "") < ($1.albumName ?? "") }
            return $0.id < $1.id
        }
    }
}
