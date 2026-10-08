// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

@Observable
@MainActor
final class AlbumDetailViewModel {
    var albumName: String = ""
    var artistName: String? = nil
    var year: Int? = nil
    var genre: String? = nil
    var releaseDate: ItemDate? = nil
    var recordLabels: [String] = []
    /// Copyright / ℗ text carried in a track's ID3 `comment` tag when the server does not
    /// expose an album-level `recordLabels`/copyright field.
    var trackCopyright: String? = nil
    var albumDescription: String? = nil
    var totalDurationSeconds: Int = 0
    var songCount: Int = 0
    var coverArtId: String? = nil
    var artistId: String? = nil
    var songs: [DisplayableSong] = []
    /// Other editions of this album (remasters / anniversary / deluxe), same artist.
    var otherAlbumVersions: [AlbumID3] = []
    /// Other albums by the same artist (excludes the current album and `otherAlbumVersions`).
    var moreAlbumsByArtist: [AlbumID3] = []
    var isLoadingMoreAlbums = false
    var isOffline: Bool = false
    var isLoading = false
    /// Core album metadata and tracks are ready to render. Secondary description,
    /// label and "more by" enrichment may continue after this becomes true.
    var isPrimaryContentReady = false
    var error: UserFacingError?
    var isDownloadingAlbum = false
    var downloadingIds: Set<String> = []

    private var loadedAlbum: AlbumID3?
    private let albumId: String
    private let libraryService: any LibraryServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let toastService: ToastService
    private let serverState: ServerState
    private var loadGeneration = 0

    init(
        albumId: String,
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        toastService: ToastService,
        serverState: ServerState
    ) {
        self.albumId = albumId
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.toastService = toastService
        self.serverState = serverState
    }

    func load() async {
        guard !Task.isCancelled else { return }
        let generation = loadGeneration + 1
        loadGeneration = generation
        isLoading = true
        isPrimaryContentReady = false
        error = nil
        if serverState.isOnline {
            await loadFromAPI(generation: generation)
        } else {
            isOffline = true
            _ = await loadFromLocal()
        }
        guard generation == loadGeneration else { return }
        isLoading = false
        isDownloadingAlbum = await downloadService.isDownloadingAlbum(albumId)
    }

    private func loadFromAPI(generation: Int) async {
        do {
            let apiAlbum = try await libraryService.album(id: albumId)
            guard generation == loadGeneration else { return }
            // Empty-success guard: behind a captive proxy / Cloudflare-WARP edge the server
            // is reachable but answers 200 with no songs. That never throws, so the catch
            // below can't help — treat an empty result exactly like a failure and prefer the
            // downloaded copy before clobbering the UI with an empty state.
            if (apiAlbum.song ?? []).isEmpty, await loadFromLocal() { return }
            guard generation == loadGeneration else { return }
            loadedAlbum = apiAlbum
            guard let serverId = serverState.activeServer?.id else { return }
            let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
            let prepared = try await DisplayableSong.prepare(
                apiAlbum.song ?? [], downloadedIDs: downloadedIds, sortedBy: Self.albumTrackOrder
            )
            guard generation == loadGeneration, serverState.activeServer?.id == serverId else { return }
            albumName = apiAlbum.name
            artistName = apiAlbum.artist
            year = apiAlbum.year
            genre = apiAlbum.genre
            releaseDate = apiAlbum.releaseDate ?? apiAlbum.originalReleaseDate
            recordLabels = apiAlbum.recordLabels?.map(\.name) ?? []
            trackCopyright = Self.findTrackCopyright((apiAlbum.song ?? []).map(\.comment))
            totalDurationSeconds = apiAlbum.duration
            songCount = apiAlbum.songCount
            coverArtId = apiAlbum.coverArt
            artistId = apiAlbum.artistId
            songs = prepared
            isOffline = false
            isPrimaryContentReady = true

            // Start More By as soon as artistId is known — don't wait on albumInfo / enrichment.
            async let moreByTask: Void = loadMoreAlbumsByArtist(generation: generation)

            let albumInfo = try? await libraryService.albumInfo(id: albumId)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            albumDescription = Self.resolveAlbumDescription(
                infoNotes: albumInfo?.notes,
                songs: apiAlbum.song ?? []
            )
            await enrichDescriptionIfNeeded(musicBrainzId: albumInfo?.musicBrainzId, generation: generation)
            await enrichRecordLabelIfNeeded(generation: generation)
            await moreByTask
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            if UserFacingError.isCancellation(error) { return }
            // Server unreachable (airplane mode with stale isOnline, VPN-satisfied path,
            // server down): fall back to the downloaded copy before surfacing an error.
            if await loadFromLocal() { return }
            self.error = UserFacingError.from(error)
        }
    }

    /// Detects a copyright / phonogram marker (`℗`, `©`, `®`, or `copyright:`) among track
    /// comments. Many servers fold the ID3 `TCOP`/`TPUB` copyright text into the COMMENT field.
    ///
    /// Returns only the copyright block (the description portion is stripped) and picks the
    /// first track that carries one.
    nonisolated static func findTrackCopyright(_ comments: [String?]) -> String? {
        for raw in comments {
            if let copyright = splitComment(raw).copyright {
                return copyright
            }
        }
        return nil
    }

    /// Splits a single `comment` string into its copyright block and description.
    ///
    /// Two forms are supported:
    /// 1. An explicit `[[COPYRIGHT]]…[[/COPYRIGHT]]` block — matched with a single regex pass and
    ///    treated as authoritative. Everything outside the block (markers removed) becomes the
    ///    description, so the copyright never leaks into the About text.
    /// 2. A legacy heuristic fallback for comments that carry ID3 `TCOP`/`TPUB` text as plain
    ///    lines: a line opening a copyright block (phonogram/copyright marker) starts the block,
    ///    which continues until a blank line.
    nonisolated static func splitComment(_ raw: String?) -> (copyright: String?, description: String?) {
        guard let raw else { return (nil, nil) }

        let (markedCopyright, withoutMarkers) = extractMarkedCopyright(from: raw)
        if let withoutMarkers {
            let description = compactDescription(withoutMarkers.components(separatedBy: .newlines))
            return (markedCopyright, description)
        }

        let lines = raw.components(separatedBy: .newlines)
        var blocks: [[String]] = []
        var descriptionLines: [String] = []
        var currentBlock: [String]?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentBlock != nil {
                if trimmed.isEmpty {
                    blocks.append(currentBlock!)
                    currentBlock = nil
                } else {
                    currentBlock!.append(line)
                }
            } else if isCopyrightLine(trimmed) {
                currentBlock = [line]
            } else {
                descriptionLines.append(line)
            }
        }
        if let currentBlock {
            blocks.append(currentBlock)
        }

        let copyright = blocks.first.flatMap { joinedBlock($0) }
        let description = compactDescription(descriptionLines)
        return (copyright, description)
    }

    /// Extracts an explicit `[[COPYRIGHT]]…[[/COPYRIGHT]]` block from a comment.
    ///
    /// The first block's inner text is the copyright; every such block is removed from the
    /// returned `withoutMarkers` text. Returns `(nil, nil)` when no marker block is present so
    /// callers can distinguish "no markers" from "markers present but empty body".
    nonisolated private static func extractMarkedCopyright(
        from raw: String
    ) -> (copyright: String?, withoutMarkers: String?) {
        let pattern = #"\[\[COPYRIGHT\]\]([\s\S]*?)\[\[/COPYRIGHT\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, nil) }
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty else { return (nil, nil) }

        let copyright: String?
        if let first = matches.first, let bodyRange = Range(first.range(at: 1), in: raw) {
            let trimmed = String(raw[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            copyright = trimmed.isEmpty ? nil : trimmed
        } else {
            copyright = nil
        }

        let withoutMarkers = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return (copyright, withoutMarkers)
    }

    /// A line opens a copyright block when it contains a phonogram/copyright symbol or starts
    /// with a copyright marker word such as `copyright`, `(p)`, or `p `.
    nonisolated private static func isCopyrightLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let symbols = ["℗", "©", "®"]
        if symbols.contains(where: line.contains) { return true }
        let lowered = line.lowercased()
        return lowered.hasPrefix("copyright")
            || lowered.hasPrefix("(p)")
            || lowered.hasPrefix("p ")
            || lowered.hasPrefix("(c)")
            || lowered.hasPrefix("c ")
    }

    /// Joins a copyright block, preserving original newlines exactly as carried in the tag.
    nonisolated private static func joinedBlock(_ lines: [String]) -> String? {
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Joins description lines, dropping surrounding whitespace and collapsing stray blank lines.
    nonisolated private static func compactDescription(_ lines: [String]) -> String? {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = trimmed.firstIndex(where: { !$0.isEmpty }),
              let last = trimmed.lastIndex(where: { !$0.isEmpty }) else { return nil }

        var out: [String] = []
        var collapsed = true
        for line in trimmed[first...last] {
            if line.isEmpty {
                if !collapsed {
                    out.append("")
                    collapsed = true
                }
            } else {
                out.append(line)
                collapsed = false
            }
        }
        return out.joined(separator: "\n")
    }

    /// Server returned no `recordLabels` → fetch the label from MusicBrainz (free, no key)
    /// when metadata enrichment is enabled. Supplies the "℗" footer line.
    private func enrichRecordLabelIfNeeded(generation: Int) async {
        guard recordLabels.isEmpty, !Task.isCancelled else { return }
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let label = await ExternalDescriptionService.shared.albumRecordLabel(
            albumName: name,
            artistName: artistName
        ) {
            guard generation == loadGeneration else { return }
            recordLabels = [label]
        }
    }

    /// Disk cache (with TTL refresh) → Apple Music editorialNotes → Wikipedia / MusicBrainz.
    private func enrichDescriptionIfNeeded(musicBrainzId: String?, generation: Int) async {
        guard !Task.isCancelled else { return }
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        let existing = albumDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Short Last.fm stubs ("n/a", one sentence) should not block richer external copy.
        guard existing.isEmpty || Self.isStubDescription(existing) else { return }
        let name = albumName
        guard !name.isEmpty else { return }

        let cached = await DescriptionCache.shared.lookup(
            kind: .album,
            name: name,
            artist: artistName,
            musicBrainzId: musicBrainzId
        )
        guard generation == loadGeneration else { return }
        if let cached {
            albumDescription = cached.text
            if !cached.needsRefresh { return }
        }

        // Prefer Apple Music catalog copy when a developer JWT is configured.
        if let apple = await AppleMusicCatalogService.shared.albumEditorialNotes(
            albumName: name,
            artistName: artistName
        ), let plain = Self.plainTextDescription(from: apple) {
            guard generation == loadGeneration else { return }
            albumDescription = plain
            await DescriptionCache.shared.store(
                plain,
                kind: .album,
                name: name,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
            return
        }

        if let external = await ExternalDescriptionService.shared.albumDescription(
            albumName: name,
            artistName: artistName,
            musicBrainzId: musicBrainzId
        ), let plain = Self.plainTextDescription(from: external) {
            guard generation == loadGeneration else { return }
            albumDescription = plain
            await DescriptionCache.shared.store(
                plain,
                kind: .album,
                name: name,
                artist: artistName,
                musicBrainzId: musicBrainzId,
                source: .external
            )
        }
    }

    /// Last.fm / server often return tiny placeholders that aren't useful About copy.
    nonisolated private static func isStubDescription(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered == "n/a" || lowered == "na" || lowered == "none" || lowered == "null" {
            return true
        }
        // Fewer than ~2 short sentences — treat as stub and allow Wikipedia to replace.
        return text.count < 80
    }

    func loadMoreAlbumsByArtist(generation: Int? = nil) async {
        let generation = generation ?? loadGeneration
        guard let artistId, !artistId.isEmpty else {
            otherAlbumVersions = []
            moreAlbumsByArtist = []
            return
        }
        isLoadingMoreAlbums = true
        defer {
            if generation == loadGeneration { isLoadingMoreAlbums = false }
        }
        do {
            let artist = try await libraryService.artist(id: artistId)
            guard generation == loadGeneration else { return }
            let siblings = (artist.album ?? []).filter { $0.id != albumId }
            let versions = AlbumVersionMatcher.otherVersions(
                of: albumName,
                excludingId: albumId,
                among: siblings
            )
            let versionIds = Set(versions.map(\.id))
            otherAlbumVersions = ArtistAlbumCategorizer.sortedByNewest(versions)
            moreAlbumsByArtist = ArtistAlbumCategorizer.sortedByNewest(
                siblings.filter { !versionIds.contains($0.id) }
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            otherAlbumVersions = []
            moreAlbumsByArtist = []
        }
    }

    nonisolated static func albumTrackOrder(_ lhs: DisplayableSong, _ rhs: DisplayableSong) -> Bool {
        let ld = lhs.discNumber ?? 1
        let rd = rhs.discNumber ?? 1
        if ld != rd { return ld < rd }
        return (lhs.trackNumber ?? Int.max) < (rhs.trackNumber ?? Int.max)
    }

    /// Prefer server notes, then a shared ID3 comment tag across tracks.
    nonisolated static func resolveAlbumDescription(infoNotes: String?, songs: [Song]) -> String? {
        if let fromInfo = plainTextDescription(from: infoNotes), !isStubDescription(fromInfo) {
            return fromInfo
        }
        if let fromComments = descriptionFromSongComments(songs) {
            return fromComments
        }
        return plainTextDescription(from: infoNotes)
    }

    /// When many tracks share the same COMMENT tag, treat it as the album About text.
    /// The copyright portion of each comment is stripped first so it never leaks into the
    /// description block (it is shown in the footer instead).
    nonisolated static func descriptionFromSongComments(_ songs: [Song]) -> String? {
        var counts: [String: Int] = [:]
        for song in songs {
            guard let splitDescription = splitComment(song.comment).description,
                  let plain = plainTextDescription(from: splitDescription),
                  !plain.isEmpty,
                  !isTechnicalComment(plain) else { continue }
            counts[plain, default: 0] += 1
        }
        guard let best = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count < rhs.key.count
        }) else { return nil }

        // Accept shared comments, or any single descriptive COMMENT tag (≥20 chars).
        let majority = best.value * 2 >= max(songs.count, 1) || best.value >= 2
        let descriptive = best.key.count >= 20
        guard majority || descriptive else { return nil }
        return best.key
    }

    nonisolated private static func isTechnicalComment(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let technical = [
            "dolby atmos", "dolby audio", "temporal", "joc", "explicit",
            "itunes_cddb", "encoded by", "ripped by", "track ",
        ]
        if technical.contains(where: { lowered.contains($0) }) && text.count < 80 {
            return true
        }
        return isStubDescription(text) && text.count < 24
    }

    /// Last.fm / OpenSubsonic notes often arrive as HTML — strip tags for display.
    nonisolated static func plainTextDescription(from raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</p\s*>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Returns true when a downloaded copy with at least one track was loaded.
    /// Sets isOffline only on success — a transient online failure must not flip
    /// the UI into offline mode while songs from a previous load are still shown.
    @discardableResult
    private func loadFromLocal() async -> Bool {
        guard let serverId = serverState.activeServer?.id,
              let data = await downloadService.localAlbumData(albumId: albumId, serverId: serverId),
              !data.songs.isEmpty else { return false }
        albumName = data.albumName
        artistName = data.artistName
        coverArtId = data.coverArtId
        songCount = data.songs.count
        songs = data.songs
        isPrimaryContentReady = true
        // Offline records carry no year/genre/artistId — clear stale online values so a re-load after going
        // offline (the long-lived VM re-runs load() on connectivity change) doesn't keep showing them.
        year = nil
        genre = nil
        releaseDate = nil
        recordLabels = []
        albumDescription = nil
        otherAlbumVersions = []
        moreAlbumsByArtist = []
        totalDurationSeconds = 0
        artistId = nil
        isOffline = true
        return true
    }

    func downloadAlbum() async {
        guard let album = loadedAlbum, let serverId = serverState.activeServer?.id else { return }
        isDownloadingAlbum = true
        defer { isDownloadingAlbum = false }
        do {
            try await downloadService.download(album: album, serverId: serverId)
        } catch {
            toastService.showError(UserFacingError.from(error).displayMessage)
        }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        songs = songs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
    }

    func cancelAlbumDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        for song in songs {
            await downloadService.cancelDownload(songId: song.id, serverId: serverId)
        }
        isDownloadingAlbum = false
    }

    func downloadSong(id: String) async {
        guard let song = loadedAlbum?.song?.first(where: { $0.id == id }),
              let serverId = serverState.activeServer?.id else { return }
        downloadingIds.insert(id)
        defer { downloadingIds.remove(id) }
        do {
            try await downloadService.download(song: song, serverId: serverId)
        } catch {
            toastService.showError(UserFacingError.from(error).displayMessage)
        }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        if let idx = songs.firstIndex(where: { $0.id == id }) {
            songs[idx] = songs[idx].withDownloaded(allDownloaded.contains(id))
        }
    }

    func downloadMissingTracks() async {
        guard let album = loadedAlbum,
              let serverId = serverState.activeServer?.id,
              let allSongs = album.song else { return }
        let downloadedIds = Set(songs.filter { $0.isDownloaded }.map(\.id))
        let missing = allSongs.filter { !downloadedIds.contains($0.id) }
        guard !missing.isEmpty else { return }
        isDownloadingAlbum = true
        defer { isDownloadingAlbum = false }
        var anyFailed = false
        for song in missing {
            do {
                try await downloadService.download(song: song, serverId: serverId)
            } catch {
                anyFailed = true
            }
        }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        songs = songs.map { $0.withDownloaded(allDownloaded.contains($0.id)) }
        if anyFailed, !songs.contains(where: { $0.isDownloaded }) {
            toastService.showError(UserFacingError.downloadFailed.displayMessage)
        }
    }

    func deleteDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        try? await downloadService.remove(albumId: albumId, serverId: serverId)
        songs = songs.map { $0.withDownloaded(false) }
    }
}
