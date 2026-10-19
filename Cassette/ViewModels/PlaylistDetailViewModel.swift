// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI
import SwiftSonic
import OSLog

@Observable
@MainActor
final class PlaylistDetailViewModel {
    var name: String = ""
    var owner: String? = nil
    var coverArtId: String? = nil
    var songs: [DisplayableSong] = []
    var isOffline: Bool = false
    var isLoading = false
    var error: UserFacingError?
    var isDownloadingPlaylist = false
    var downloadingIds: Set<String> = []

    private(set) var playlistDetail: PlaylistWithSongs?
    private(set) var generatedUpdatedAt: Date?
    let generatedSource: GeneratedPlaylistSource?
    var isGenerated: Bool { generatedSource != nil }
    var updatedAt: Date? { generatedUpdatedAt ?? playlistDetail?.changed }
    private let generatedLoader: (@MainActor (Bool) async -> GeneratedPlaylistSnapshot?)?
    private var loadGeneration = 0
    private struct Occurrence { let id: UUID; let songID: String }
    @ObservationIgnored private var occurrences: [Occurrence] = []
    private struct Edit { let id: UUID; let task: Task<Void, Never> }
    @ObservationIgnored private var pendingEdit: Edit?
    private let playlistId: String
    private let libraryService: any LibraryServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let playlistService: any PlaylistServiceProtocol
    private let toastService: ToastService
    private let serverState: ServerState

    init(
        playlistId: String,
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        playlistService: any PlaylistServiceProtocol,
        toastService: ToastService,
        serverState: ServerState,
        generatedSource: GeneratedPlaylistSource? = nil,
        generatedLoader: (@MainActor (Bool) async -> GeneratedPlaylistSnapshot?)? = nil
    ) {
        self.playlistId = playlistId
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.playlistService = playlistService
        self.toastService = toastService
        self.serverState = serverState
        self.generatedSource = generatedSource
        self.generatedLoader = generatedLoader
    }

    func load(forceRefresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        if isGenerated {
            await loadGenerated(generation: generation, forceRefresh: forceRefresh)
        } else if serverState.isOnline {
            await loadFromAPI(generation: generation)
        } else {
            isOffline = true
            await loadFromLocal(generation: generation)
        }
        guard generation == loadGeneration else { return }
        isLoading = false
        let downloading = await downloadService.isDownloadingPlaylist(playlistId)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        isDownloadingPlaylist = downloading
    }

    private func loadGenerated(generation: Int, forceRefresh: Bool) async {
        guard let sid = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: sid) else { return }
        if !serverState.isOnline {
            owner = serverState.activeServer?.username
            isOffline = true
            _ = await loadFromLocal(generation: generation)
            return
        }
        let snapshot = await generatedLoader?(forceRefresh)
        guard generation == loadGeneration, serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
        guard let snapshot else {
            if await loadFromLocal(generation: generation) { return }
            error = .unexpected
            return
        }
        let downloaded = await downloadService.downloadedSongIds(serverId: sid)
        guard generation == loadGeneration, serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
        name = snapshot.name
        owner = snapshot.owner
        generatedUpdatedAt = snapshot.updatedAt
        songs = snapshot.tracks.map { $0.withDownloaded(downloaded.contains($0.id)) }
        resetOccurrences()
        isOffline = false
    }

    private func loadFromAPI(generation: Int) async {
        do {
            let apiPlaylist = try await libraryService.playlist(id: playlistId)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Empty-success guard: behind a captive proxy / Cloudflare-WARP edge the server
            // is reachable but answers 200 with no entries. That never throws, so the catch
            // below can't help — treat an empty result exactly like a failure and prefer the
            // downloaded copy before clobbering the UI with an "Empty Playlist" state.
            if (apiPlaylist.entry ?? []).isEmpty, await loadFromLocal(generation: generation) { return }
            guard let serverId = serverState.activeServer?.id else { return }
            let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
            let prepared = try await DisplayableSong.prepare(apiPlaylist.entry ?? [], downloadedIDs: downloadedIds)
            guard generation == loadGeneration, !Task.isCancelled,
                  serverState.activeServer?.id == serverId else { return }
            playlistDetail = apiPlaylist
            name = apiPlaylist.name
            owner = apiPlaylist.owner
            coverArtId = apiPlaylist.coverArt
            songs = prepared
            resetOccurrences()
            isOffline = false
            // Self-heal: if this playlist was downloaded before songIds existed (or with an
            // empty list), repair it now from the authoritative order so it reads offline next time.
            await downloadService.backfillPlaylistSongIds(
                playlistId: playlistId,
                serverId: serverId,
                orderedSongIds: (apiPlaylist.entry ?? []).map(\.id)
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // Server unreachable (airplane mode with stale isOnline, VPN-satisfied path,
            // server down): fall back to the downloaded copy before surfacing an error.
            if await loadFromLocal(generation: generation) { return }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.error = UserFacingError.from(error)
        }
    }

    /// Returns true when a downloaded copy with at least one track was loaded.
    /// Sets isOffline only on success — a transient online failure must not flip
    /// the UI into offline mode while songs from a previous load are still shown.
    @discardableResult
    private func loadFromLocal(generation: Int) async -> Bool {
        guard let serverId = serverState.activeServer?.id,
              let data = await downloadService.localPlaylistData(playlistId: playlistId, serverId: serverId),
              !data.songs.isEmpty, generation == loadGeneration, !Task.isCancelled,
              serverState.activeServer?.id == serverId else { return false }
        name = data.name
        coverArtId = data.coverArtId
        songs = data.songs
        resetOccurrences()
        isOffline = true
        return true
    }

    func downloadPlaylist() async {
        if isGenerated { await downloadGeneratedPlaylist(); return }
        guard let playlist = playlistDetail, let serverId = serverState.activeServer?.id else { return }
        isDownloadingPlaylist = true
        defer { isDownloadingPlaylist = false }
        do {
            try await downloadService.download(playlist: playlist, serverId: serverId)
        } catch {
            if !UserFacingError.isCancellation(error) {
                toastService.showError(UserFacingError.from(error).displayMessage)
            }
        }
        let downloadedIds = await downloadService.downloadedSongIds(serverId: serverId)
        songs = songs.map { $0.withDownloaded(downloadedIds.contains($0.id)) }
    }

    func cancelPlaylistDownload() async {
        guard let serverId = serverState.activeServer?.id else { return }
        await downloadService.cancelPlaylistDownload(playlistId: playlistId, serverId: serverId)
        for song in songs {
            await downloadService.cancelDownload(songId: song.id, serverId: serverId)
        }
        isDownloadingPlaylist = false
    }

    func downloadSong(id: String) async {
        guard let serverId = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: serverId) else { return }
        downloadingIds.insert(id)
        defer { downloadingIds.remove(id) }
        do {
            let song: Song
            if let entry = playlistDetail?.entry?.first(where: { $0.id == id }) { song = entry }
            else if isGenerated, songs.contains(where: { $0.id == id }) { song = try await libraryService.song(id: id) }
            else { return }
            guard serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
            try await downloadService.download(song: song, serverId: serverId)
        } catch {
            toastService.showError(UserFacingError.from(error).displayMessage)
        }
        let allDownloaded = await downloadService.downloadedSongIds(serverId: serverId)
        guard serverState.requestIsCurrent(identity) else { return }
        if let idx = songs.firstIndex(where: { $0.id == id }) {
            songs[idx] = songs[idx].withDownloaded(allDownloaded.contains(id))
        }
    }

    func downloadMissingTracks() async {
        if isGenerated { await downloadGeneratedPlaylist(); return }
        guard let playlist = playlistDetail,
              let serverId = serverState.activeServer?.id,
              let allSongs = playlist.entry else { return }
        let downloadedIds = Set(songs.filter { $0.isDownloaded }.map(\.id))
        let missing = allSongs.filter { !downloadedIds.contains($0.id) }
        guard !missing.isEmpty else { return }
        isDownloadingPlaylist = true
        defer { isDownloadingPlaylist = false }
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

    /// Materializes full server song metadata only when the user requests a download.
    /// The download store owns the local snapshot; no generated ID is sent to playlist APIs.
    private func downloadGeneratedPlaylist() async {
        guard !isDownloadingPlaylist, !songs.isEmpty,
              let sid = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: sid) else { return }
        let selected = songs
        let generation = loadGeneration
        isDownloadingPlaylist = true
        defer { isDownloadingPlaylist = false }
        do {
            var entries: [Song] = []
            for track in selected {
                entries.append(try await libraryService.song(id: track.id))
                guard generation == loadGeneration, serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
            }
            let snapshot = PlaylistWithSongs(id: playlistId, name: name, songCount: entries.count,
                duration: Int(selected.reduce(0) { $0 + $1.duration }), owner: owner,
                changed: generatedUpdatedAt, entry: entries)
            try await downloadService.download(playlist: snapshot, serverId: sid)
            let downloaded = await downloadService.downloadedSongIds(serverId: sid)
            guard generation == loadGeneration, serverState.requestIsCurrent(identity), !Task.isCancelled else { return }
            songs = songs.map { $0.withDownloaded(downloaded.contains($0.id)) }
        } catch {
            if !UserFacingError.isCancellation(error), serverState.requestIsCurrent(identity) {
                toastService.showError(UserFacingError.from(error).displayMessage)
            }
        }
    }

    func deleteDownload() async {
        guard let serverId = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: serverId) else { return }
        // The playlist removal owns the reference checks for other playlists and albums.
        // Removing each song first bypassed those checks and destroyed shared files.
        try? await downloadService.remove(playlistId: playlistId, serverId: serverId)
        let remaining = await downloadService.downloadedSongIds(serverId: serverId)
        guard serverState.requestIsCurrent(identity) else { return }
        songs = songs.map { $0.withDownloaded(remaining.contains($0.id)) }
    }

    private func resetOccurrences() {
        occurrences = songs.map { Occurrence(id: UUID(), songID: $0.id) }
    }

    private func ensureOccurrences() {
        if occurrences.map(\.songID) != songs.map(\.id) { resetOccurrences() }
    }

    /// Stable occurrences retain the user's selection while an earlier edit may fail and
    /// restore a row. Server index mutations must follow the same order as UI mutations.
    private func enqueueEdit(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = pendingEdit?.task
        let id = UUID()
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        pendingEdit = Edit(id: id, task: task)
        defer { if pendingEdit?.id == id { pendingEdit = nil } }
        await task.value
    }

    func removeTrack(at index: Int) async {
        guard !isGenerated, songs.indices.contains(index), let serverID = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: serverID) else { return }
        ensureOccurrences()
        let selected = occurrences[index].id
        let generation = loadGeneration
        await enqueueEdit { [self] in
            guard serverState.requestIsCurrent(identity), generation == loadGeneration,
                  let currentIndex = occurrences.firstIndex(where: { $0.id == selected }),
                  songs.indices.contains(currentIndex) else { return }
            let removed = songs.remove(at: currentIndex)
            let occurrence = occurrences.remove(at: currentIndex)
            do {
                try await playlistService.removeTracks(playlistId: playlistId, indices: [currentIndex])
            } catch {
                guard serverState.requestIsCurrent(identity), generation == loadGeneration else { return }
                let restoreIndex = min(currentIndex, songs.count)
                songs.insert(removed, at: restoreIndex)
                occurrences.insert(occurrence, at: restoreIndex)
                if !UserFacingError.isCancellation(error) { toastService.showError("Failed to remove track") }
            }
        }
    }

    func moveTracks(from source: IndexSet, to destination: Int) async {
        guard !isGenerated, !source.isEmpty, source.allSatisfy({ songs.indices.contains($0) }),
              (0...songs.count).contains(destination), let serverID = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: serverID) else { return }
        ensureOccurrences()
        let selected = Set(source.map { occurrences[$0].id })
        let anchor = occurrences.dropFirst(destination).first { !selected.contains($0.id) }?.id
        let generation = loadGeneration
        await enqueueEdit { [self] in
            guard serverState.requestIsCurrent(identity), generation == loadGeneration else { return }
            let currentSource = IndexSet(occurrences.enumerated().compactMap { selected.contains($0.element.id) ? $0.offset : nil })
            guard currentSource.count == selected.count else { return }
            let currentDestination = anchor.flatMap { target in occurrences.firstIndex { $0.id == target } } ?? songs.count
            let originalSongs = songs
            let originalOccurrences = occurrences
            songs.move(fromOffsets: currentSource, toOffset: currentDestination)
            occurrences.move(fromOffsets: currentSource, toOffset: currentDestination)
            do {
                try await playlistService.reorderTracks(playlistId: playlistId, orderedSongIds: songs.map(\.id))
            } catch {
                guard serverState.requestIsCurrent(identity), generation == loadGeneration else { return }
                songs = originalSongs
                occurrences = originalOccurrences
                if !UserFacingError.isCancellation(error) { toastService.showError("Failed to reorder tracks") }
            }
        }
    }
}
