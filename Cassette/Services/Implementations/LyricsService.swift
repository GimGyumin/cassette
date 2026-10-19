// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

/// Fetches and caches structured lyrics for the active server, with optional LRCLIB fallback.
///
/// All persistence uses a private ModelContext created per operation.
/// No UIKit or SwiftUI imports — this actor is platform-agnostic.
actor LyricsService {
    nonisolated enum FetchPolicy: Sendable, Equatable {
        case interactive
        /// Backfill favors complete server results over a fast external fallback.
        case libraryGeneration
    }
    private let serverService: any ServerServiceProtocol
    private let modelContainer: ModelContainer
    private let externalProvider: any ExternalLyricsProviding
    private let mediaIdentityService: MediaIdentityService?
    private let rawLyricsSession: URLSession

    init(
        serverService: any ServerServiceProtocol,
        modelContainer: ModelContainer,
        externalProvider: any ExternalLyricsProviding = CompositeExternalLyricsClient(),
        mediaIdentityService: MediaIdentityService? = nil,
        rawLyricsSession: URLSession = .shared
    ) {
        self.serverService = serverService
        self.modelContainer = modelContainer
        self.externalProvider = externalProvider
        self.mediaIdentityService = mediaIdentityService
        self.rawLyricsSession = rawLyricsSession
    }

    // MARK: - Fetch

    /// Returns lyrics for a song using the user's `LyricsSourcePreference`.
    /// Prefers synced lyrics whenever both server and external sources are available.
    func fetchLyrics(
        forSongId songId: String,
        serverId: UUID,
        match: LyricsMatchInfo? = nil,
        policy: FetchPolicy = .interactive
    ) async throws -> LyricsList {
        let preference = LyricsSourcePreference.current()
        let cached = await cachedLyrics(songId: songId, serverId: serverId)

        switch preference {
        case .embedded:
            if let cached, policy == .interactive, await shouldReturnCached(cached) {
                return cached.list
            }
            do {
                return try await fetchEmbedded(songId: songId, serverId: serverId)
            } catch {
                if let cached, !cached.list.structuredLyrics.isEmpty {
                    return cached.list
                }
                throw error
            }

        case .external:
            if let cached, Self.hasSynced(cached.list) { return cached.list }
            if let match, match.canQueryExternal {
                do {
                    let external = try await externalProvider.fetchLyrics(match: match)
                    await persistLyrics(external, songId: songId, serverId: serverId, fetchedWithEnhanced: false)
                    return external
                } catch LyricsError.notFound {
                    if let cached { return cached.list }
                    throw LyricsError.notFound
                } catch {
                    if let cached { return cached.list }
                    throw error
                }
            }
            if let cached { return cached.list }
            throw LyricsError.notFound

        case .embeddedWithFallback:
            if let cached, policy == .interactive, await shouldReturnCached(cached) {
                return cached.list
            }

            // Both sources are queried at once. The server keeps a short head start — so a karaoke
            // payload from the server still wins the way it always did — while the external lookup
            // (usually far faster) is already on the wire. Previously the external provider was not
            // even asked until the server had answered, so a track whose server has no lyrics kept
            // the lyrics screen waiting for the server's full timeout (~8 s in the field).
            let resolution = await resolveEmbeddedWithFallback(songId: songId, serverId: serverId, match: match, policy: policy)
            switch resolution {
            case .lyrics(let list):
                return list
            case .failure(let error):
                if let cached, !cached.list.structuredLyrics.isEmpty {
                    return cached.list
                }
                throw error
            }
        }
    }

    // MARK: - Server + external race

    /// How long the server may take on its own before a faster external answer is accepted.
    /// A server that *has* lyrics answers well inside this window, so karaoke still wins.
    nonisolated static let serverHeadStart: Duration = .milliseconds(1500)

    enum EmbeddedResolution {
        case lyrics(LyricsList)
        case failure(any Error)
    }

    /// Which source should be shown once both have had their chance.
    enum LyricsChoice {
        case server(LyricsList)
        case external(LyricsList)
    }

    private enum RaceEvent: Sendable {
        case server(Result<LyricsList, any Error>)
        case external(LyricsList?)
        case headStartElapsed
    }

    /// Runs the server fetch and the external fallback concurrently and returns whichever source
    /// should be shown. The losing lookup is cancelled as soon as a decision is made.
    private func resolveEmbeddedWithFallback(
        songId: String,
        serverId: UUID,
        match: LyricsMatchInfo?,
        policy: FetchPolicy
    ) async -> EmbeddedResolution {
        let externalMatch: LyricsMatchInfo? = (match?.canQueryExternal == true) ? match : nil
        let provider = externalProvider

        return await withTaskGroup(of: RaceEvent.self) { group in
            group.addTask {
                .server(await Self.capture {
                    try await self.fetchEmbedded(songId: songId, serverId: serverId)
                })
            }
            if externalMatch != nil {
                group.addTask {
                    .external(await Self.fetchExternal(provider: provider, match: match))
                }
            }
            if policy == .interactive {
                group.addTask {
                    try? await Task.sleep(for: Self.serverHeadStart)
                    return .headStartElapsed
                }
            }

            var serverResult: Result<LyricsList, any Error>?
            var externalList: LyricsList?
            var externalSettled = externalMatch == nil
            var headStartElapsed = false

            while let event = await group.next() {
                switch event {
                case .server(let result):
                    serverResult = result
                    if case .failure(let error) = result {
                        Logger.lyrics.debug(
                            "Embedded lyrics unavailable — songId=\(songId, privacy: .public): \(error, privacy: .public)"
                        )
                    }
                case .external(let list):
                    externalList = list
                    externalSettled = true
                case .headStartElapsed:
                    headStartElapsed = true
                }

                let choice = Self.chooseSource(
                    embedded: try? serverResult?.get(),
                    embeddedSettled: serverResult != nil,
                    external: externalList,
                    externalSettled: externalSettled,
                    serverHeadStartElapsed: headStartElapsed,
                    waitForServer: policy == .libraryGeneration
                )
                guard let choice else { continue }
                group.cancelAll()
                switch choice {
                case .external(let list):
                    await persistLyrics(list, songId: songId, serverId: serverId, fetchedWithEnhanced: false)
                    return .lyrics(list)
                case .server(let list):
                    return .lyrics(list)
                }
            }

            if let serverResult, case .failure(let error) = serverResult {
                return .failure(error)
            }
            return .failure(LyricsError.notFound)
        }
    }

    /// Single decision point for the race. `nil` means "keep waiting — a better source may arrive".
    ///
    /// Mirrors the sequential rules this replaced: server karaoke is never replaced by weaker
    /// external LRC, an external karaoke/synced payload is still preferred as an upgrade, and an
    /// empty server answer defers to any usable external one.
    nonisolated static func chooseSource(
        embedded: LyricsList?,
        embeddedSettled: Bool,
        external: LyricsList?,
        externalSettled: Bool,
        serverHeadStartElapsed: Bool,
        waitForServer: Bool = false
    ) -> LyricsChoice? {
        // A whole-library pass must not cancel a slow enhanced server response
        // just because LRCLIB already returned line-synced text.
        if waitForServer, !embeddedSettled { return nil }
        // 1. Karaoke wins, wherever it came from.
        if let embedded, Self.hasKaraoke(embedded) { return .server(embedded) }
        if let external, Self.hasKaraoke(external) { return .external(external) }

        let embeddedUsable = embedded?.structuredLyrics.isEmpty == false
        let externalUsable = external?.structuredLyrics.isEmpty == false

        // 2. Server has nothing usable (yet).
        guard embeddedUsable, let embedded else {
            if externalUsable, let external {
                // Hold the line for the server's head start so a karaoke payload it is about to
                // send is not pre-empted by plain LRC.
                return serverHeadStartElapsed || embeddedSettled ? .external(external) : nil
            }
            return nil   // still pending, or nothing anywhere (caller keeps its error behaviour)
        }

        // 3. Server answered with usable lyrics: still look for an external upgrade.
        if !externalSettled { return nil }
        if let external, externalUsable,
           Self.hasSynced(external), !Self.hasSynced(embedded) {
            return .external(external)
        }
        return .server(embedded)
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// External lookup that never throws: "no external lyrics" is a normal outcome.
    private static func fetchExternal(
        provider: any ExternalLyricsProviding,
        match: LyricsMatchInfo?
    ) async -> LyricsList? {
        guard let match, match.canQueryExternal else { return nil }
        do {
            return try await provider.fetchLyrics(match: match)
        } catch {
            Logger.lyrics.debug("External lyrics fallback missed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Language Selection

    /// Picks the best StructuredLyrics set for the given locale and optional user preference.
    ///
    /// Priority:
    /// 1. Primary layers (`kind` main / unspecified) — songLyrics v2 translations are overlays.
    /// 2. Synced **karaoke** (word-level cues) — highest display priority when available.
    /// 3. User-selected `preferred` language — synced variant if available, else unsynced.
    /// 4. System locale language — synced variant if available, else unsynced.
    /// 5. Any synced set, then first available.
    ///
    /// "xxx" is normalised to "und" per OpenSubsonic spec (both mean unspecified language).
    nonisolated func selectBestLanguage(
        from list: LyricsList,
        locale: Locale = .current,
        preferred: String? = nil
    ) -> StructuredLyrics? {
        let all = list.structuredLyrics
        guard !all.isEmpty else { return nil }
        let primary = all.filter(\.isPrimaryLayer)
        let entries = primary.isEmpty ? all : primary

        func normalized(_ lang: String?) -> String? {
            lang == "xxx" ? "und" : lang
        }

        func best(among candidates: [StructuredLyrics]) -> StructuredLyrics? {
            guard !candidates.isEmpty else { return nil }
            return candidates.max(by: { lhs, rhs in
                // Prefer word-level karaoke / richer cue data (sidecar TTML) over plain LRC.
                if lhs.hasKaraokeCues != rhs.hasKaraokeCues {
                    return !lhs.hasKaraokeCues && rhs.hasKaraokeCues
                }
                let lCues = lhs.cueLine.reduce(0) { $0 + $1.cue.count }
                let rCues = rhs.cueLine.reduce(0) { $0 + $1.cue.count }
                if lCues != rCues { return lCues < rCues }
                if lhs.agents.count != rhs.agents.count {
                    return lhs.agents.count < rhs.agents.count
                }
                if lhs.synced != rhs.synced { return !lhs.synced && rhs.synced }
                return false
            })
        }

        // Word-level karaoke / agent-rich tracks win over language / locale.
        if let karaoke = best(among: entries.filter { $0.synced && $0.hasKaraokeCues }) {
            return karaoke
        }

        // Karaoke may live on a non-primary layer in some server payloads.
        if entries.count != all.count,
           let karaoke = best(among: all.filter { $0.synced && $0.hasKaraokeCues }) {
            return karaoke
        }

        // Among non-karaoke tracks, still prefer the richest synced set (more lines / cues).
        if let preferred {
            let matching = entries.filter { normalized($0.lang) == preferred }
            if let hit = best(among: matching) { return hit }
        }

        let langCode = locale.language.languageCode?.identifier ?? ""
        if !langCode.isEmpty {
            let matching = entries.filter { normalized($0.lang) == langCode }
            if let hit = best(among: matching) { return hit }
        }

        return best(among: entries)
    }

    // MARK: - Private

    private struct CachedEntry {
        let list: LyricsList
        /// `true` when this payload was fetched with `enhanced=true` (songLyrics v2).
        let fetchedWithEnhanced: Bool
        /// Original response body, retained for TTML translations and pronunciation layers.
        let rawTTML: Data?
    }

    /// Envelope stored in SwiftData so we can tell v1 LRC caches from enhanced fetches
    /// that simply had no word-level cues (avoids re-fetching forever).
    private struct PersistedLyricsCache: Codable {
        let fetchedWithEnhanced: Bool
        let lyricsList: LyricsList
        var rawTTML: Data? = nil
    }

    private nonisolated static func hasSynced(_ list: LyricsList) -> Bool {
        list.structuredLyrics.contains { $0.synced && !$0.line.isEmpty }
    }

    private nonisolated static func hasKaraoke(_ list: LyricsList) -> Bool {
        list.structuredLyrics.contains(where: \.hasKaraokeCues)
    }

    /// Return cached lyrics unless a karaoke (songLyrics v2) upgrade is still worth trying.
    /// Unsynced / empty caches never short-circuit — always re-hit the server.
    private func shouldReturnCached(_ cached: CachedEntry) async -> Bool {
        if Self.hasKaraoke(cached.list) { return true }
        guard Self.hasSynced(cached.list) else { return false }
        // Already fetched with enhanced=true — accept line-synced result (song has no cues).
        if cached.fetchedWithEnhanced { return true }
        // Legacy LRC / pre-v2 cache: only re-fetch when the server may offer word-level cues.
        switch await supportsSongLyricsV2() {
        case .some(false):
            return true
        case .some(true), .none:
            return false
        }
    }

    private func supportsSongLyricsV2() async -> Bool? {
        guard let caps = try? await serverService.makeSwiftSonicClient().loadCapabilities() else {
            return nil
        }
        return caps.supports(.songLyrics, version: 2)
    }

    /// Fetches the raw HTTP response body for `getLyricsBySongId` so we can extract
    /// TTML `<translations>` that are lost during JSON deserialization.
    func fetchRawTTML(songId: String, serverId: UUID) async -> Data? {
        if let cached = await cachedLyrics(songId: songId, serverId: serverId),
           let rawTTML = cached.rawTTML {
            return rawTTML
        }

        let rawTTML = await fetchRawTTMLFromServer(songId: songId)
        if let rawTTML,
           let cached = await cachedLyrics(songId: songId, serverId: serverId) {
            await persistLyrics(
                cached.list,
                songId: songId,
                serverId: serverId,
                fetchedWithEnhanced: cached.fetchedWithEnhanced,
                rawTTML: rawTTML
            )
        }
        return rawTTML
    }

    private func fetchRawTTMLFromServer(songId: String) async -> Data? {
        do {
            let serverId = await MainActor.run { serverService.state.activeServer?.id }
            let resolvedSongID = if let serverId {
                await MainActor.run {
                    mediaIdentityService?.resolveCurrentID(songId, serverId: serverId, entityType: .song) ?? songId
                }
            } else {
                songId
            }
            let client = try await serverService.makeSwiftSonicClient()
            // Re-use the client's own properly authed URL and just swap the endpoint path.
            guard let streamRequest = client.coverArtURL(id: resolvedSongID) else { return nil }
            // Extract the base and auth from the coverArt URL, swap path/params.
            var comps = URLComponents(url: streamRequest, resolvingAgainstBaseURL: false)
            if let path = comps?.path {
                comps?.path = (path as NSString).deletingLastPathComponent + "/getLyricsBySongId.view"
            }
            var items = comps?.queryItems ?? []
            items.removeAll { $0.name == "id" || $0.name == "size" || $0.name == "enhanced" }
            items.append(URLQueryItem(name: "id", value: resolvedSongID))
            items.append(URLQueryItem(name: "enhanced", value: "true"))
            comps?.queryItems = items
            guard let requestURL = comps?.url else { return nil }
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 15
            if let credentials = try? await serverService.activeCredentials() {
                for (key, value) in credentials.customHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            let (data, response) = try await rawLyricsSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            Logger.lyrics.debug("Raw TTML fetch skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchEmbedded(songId: String, serverId: UUID) async throws -> LyricsList {
        let resolvedSongID = await MainActor.run {
            mediaIdentityService?.resolveCurrentID(songId, serverId: serverId, entityType: .song) ?? songId
        }
        var claimsSupport = true
        do {
            let client = try await serverService.makeSwiftSonicClient()
            // Probe capabilities, but don't trust a failed/cancelled extension list —
            // a cancelled getOpenSubsonicExtensions leaves songLyrics=false even when
            // the server supports lyrics (seen after credential reentry / task cancellation).
            let capabilities = try? await client.loadCapabilities()
            claimsSupport = capabilities?.supports(.songLyrics) ?? true
            // Navidrome 0.63+ advertises songLyrics [1,2] — request karaoke / kind / agents.
            // When the probe fails, still request enhanced so we don't permanently cache LRC-only.
            let enhanced = capabilities?.supports(.songLyrics, version: 2) ?? true
            let list = try await client.getLyricsBySongId(id: resolvedSongID, enhanced: enhanced)
            guard !list.structuredLyrics.isEmpty else {
                throw LyricsError.notFound
            }
            // Also try to fetch raw TTML for embedded translations.
            let rawData = await fetchRawTTMLFromServer(songId: resolvedSongID)
            try Task.checkCancellation()
            await persistLyrics(list, songId: resolvedSongID, serverId: serverId, fetchedWithEnhanced: enhanced, rawTTML: rawData)
            return list
        } catch let error as LyricsError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || PlaybackFailure.classify(error).kind == .cancelled {
                throw CancellationError()
            }
            // Only surface "unsupported" when the capability probe was conclusive.
            if !claimsSupport, Self.looksLikeUnsupportedEndpoint(error) {
                throw LyricsError.notSupportedByServer
            }
            if let cached = await cachedLyrics(songId: songId, serverId: serverId) {
                Logger.lyrics.info("Network error, returning cached lyrics — songId=\(songId, privacy: .public)")
                return cached.list
            }
            Logger.lyrics.error("Lyrics fetch failed — songId=\(songId, privacy: .public): \(error, privacy: .public)")
            throw LyricsError.networkError(underlying: error.localizedDescription)
        }
    }

    private static func looksLikeUnsupportedEndpoint(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("not implemented")
            || text.contains("not supported")
            || text.contains("unknown method")
            || text.contains("404")
    }

    // MARK: - Library lyrics generation

    /// Classifies the richness of a fetched lyric payload for progress reporting.
    enum LyricKind: String, Sendable, Equatable, Hashable {
        /// Word-level (karaoke) timing — TTML / songLyrics v2 cues.
        case karaoke
        /// Line-level synced lyrics — LRC / ELRC.
        case synced
        /// Plain text without timing.
        case unsynced
    }

    /// Running tallies emitted alongside each per-song event.
    struct LibraryLyricsProgress: Sendable, Equatable, Hashable {
        var processed = 0
        var total = 0
        var found = 0
        var skipped = 0
        var missing = 0
        var failed = 0
    }

    /// A single song's outcome during a whole-library backfill pass.
    struct LibraryLyricsEvent: Sendable, Equatable, Hashable {
        enum Outcome: Sendable, Equatable, Hashable {
            case found(LyricKind)
            case skipped
            case missing
            case failed(String)
        }

        let songTitle: String
        let artist: String?
        let outcome: Outcome
        let progress: LibraryLyricsProgress
    }

    enum LibraryGenerationMode: Sendable {
        case appCache
        /// Always contact the server: its lyrics plugin owns sidecar file writing.
        case serverFiles
    }

    /// Fetches and caches lyrics for every song in the library, streaming a per-song
    /// progress event as it goes. Rich cached lyrics are skipped; LRC/text caches
    /// are rechecked for a server karaoke upgrade.
    ///
    /// Reuses the per-song fetch path (server `getLyricsBySongId` / nd-lyrics + LRCLIB
    /// fallback), so the cached results match what the player renders. Cancellation is
    /// cooperative: stop iterating the returned stream (or cancel the consuming task) to
    /// halt the backfill.
    func generateLibraryLyrics(
        library: any LibraryServiceProtocol,
        serverId: UUID,
        mode: LibraryGenerationMode = .appCache
    ) -> AsyncThrowingStream<LibraryLyricsEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LibraryLyricsEvent, Error>.makeStream()

        let task = Task {
            do {
                if mode == .serverFiles {
                    guard await MainActor.run(body: { self.serverService.state.activeServer?.id }) == serverId else {
                        throw CancellationError()
                    }
                }
                let generationClient = mode == .serverFiles
                    ? try await self.serverService.makeLyricsGenerationClient() : nil
                let songs = try await self.allLibrarySongs(library: library)
                let preference = LyricsSourcePreference.current()
                var progress = LibraryLyricsProgress(total: songs.count)

                for song in songs {
                    try Task.checkCancellation()
                    if mode == .serverFiles {
                        guard await MainActor.run(body: { self.serverService.state.activeServer?.id }) == serverId else {
                            throw CancellationError()
                        }
                    }
                    progress.processed += 1

                    let outcome: LibraryLyricsEvent.Outcome
                    if mode == .appCache,
                       let cached = await self.cachedLyrics(songId: song.id, serverId: serverId),
                       Self.shouldSkipLibraryCache(cached.list, preference: preference) {
                        progress.skipped += 1
                        outcome = .skipped
                    } else {
                        let match = LyricsMatchInfo(song: DisplayableSong(from: song))
                        do {
                            let list: LyricsList
                            if let generationClient {
                                // One enhanced request per track. Never substitute local or external
                                // lyrics: only a server request can trigger nd-lyrics file writing.
                                list = try await generationClient.getLyricsBySongId(id: song.id, enhanced: true)
                                try Task.checkCancellation()
                                guard await MainActor.run(body: { self.serverService.state.activeServer?.id }) == serverId else {
                                    throw CancellationError()
                                }
                                guard !list.structuredLyrics.isEmpty else { throw LyricsError.notFound }
                            } else {
                                list = try await self.fetchLyrics(
                                    forSongId: song.id, serverId: serverId, match: match, policy: .libraryGeneration
                                )
                            }
                            progress.found += 1
                            outcome = .found(Self.kind(of: list))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try Task.checkCancellation()
                            if mode == .serverFiles, !(error is LyricsError && (error as? LyricsError) == .notFound) {
                                progress.failed += 1
                                outcome = .failed(error.localizedDescription)
                            } else {
                                progress.missing += 1
                                outcome = .missing
                            }
                            Logger.lyrics.debug(
                                "Library lyrics generation missed \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }

                    continuation.yield(LibraryLyricsEvent(
                        songTitle: song.title,
                        artist: song.artist,
                        outcome: outcome,
                        progress: progress
                    ))
                }

                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }

    /// Classifies a fetched `LyricsList` by the richest timing available.
    nonisolated static func shouldSkipLibraryCache(_ list: LyricsList, preference: LyricsSourcePreference) -> Bool {
        preference == .external ? Self.hasSynced(list) : Self.hasKaraoke(list)
    }

    nonisolated static func kind(of list: LyricsList) -> LyricKind {
        if list.structuredLyrics.contains(where: \.hasKaraokeCues) {
            return .karaoke
        }
        if list.structuredLyrics.contains(where: { $0.synced && !$0.line.isEmpty }) {
            return .synced
        }
        return .unsynced
    }

    private func allLibrarySongs(library: any LibraryServiceProtocol) async throws -> [Song] {
        let pageSize = 500
        var songs: [Song] = []
        var offset = 0
        while true {
            let page = try await library.librarySongs(offset: offset, count: pageSize)
            guard !page.isEmpty else { break }
            songs.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return songs
    }

    private func cachedLyrics(songId: String, serverId: UUID) async -> CachedEntry? {
        let candidates = await MainActor.run {
            mediaIdentityService?.candidateRemoteIDs(for: songId, serverId: serverId, entityType: .song) ?? [songId]
        }
        let keys = Set(candidates.map { "\(serverId.uuidString):\($0)" })
        let context = ModelContext(modelContainer)
        let sid = serverId
        let descriptor = FetchDescriptor<CachedLyrics>(predicate: #Predicate { $0.serverId == sid })
        guard let entry = (try? context.fetch(descriptor))?.first(where: { keys.contains($0.compositeKey) }) else { return nil }
        do {
            return try Self.decodeCachedPayload(entry.jsonPayload)
        } catch {
            Logger.lyrics.error("Cache corrupted — key=\(entry.compositeKey, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func decodeCachedPayload(_ data: Data) throws -> CachedEntry {
        // New envelope first — legacy payloads are bare LyricsList JSON.
        if let envelope = try? JSONDecoder().decode(PersistedLyricsCache.self, from: data) {
            return CachedEntry(
                list: envelope.lyricsList,
                fetchedWithEnhanced: envelope.fetchedWithEnhanced,
                rawTTML: envelope.rawTTML
            )
        }
        let list = try JSONDecoder().decode(LyricsList.self, from: data)
        return CachedEntry(list: list, fetchedWithEnhanced: false, rawTTML: nil)
    }

    private func persistLyrics(
        _ list: LyricsList,
        songId: String,
        serverId: UUID,
        fetchedWithEnhanced: Bool,
        rawTTML: Data? = nil
    ) async {
        let resolvedSongID = await MainActor.run {
            mediaIdentityService?.resolveCurrentID(songId, serverId: serverId, entityType: .song) ?? songId
        }
        let envelope = PersistedLyricsCache(
            fetchedWithEnhanced: fetchedWithEnhanced,
            lyricsList: list,
            rawTTML: rawTTML
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let key = "\(serverId.uuidString):\(resolvedSongID)"
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CachedLyrics>(
            predicate: #Predicate { $0.compositeKey == key }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            // A foreground lookup may have completed while a bulk lookup was
            // awaiting the network. A late LRC response must not overwrite its cues.
            if let previous = try? Self.decodeCachedPayload(existing.jsonPayload),
               Self.hasKaraoke(previous.list), !Self.hasKaraoke(list) {
                return
            }
            context.delete(existing)
        }
        context.insert(CachedLyrics(songId: resolvedSongID, serverId: serverId, jsonPayload: data))
        try? context.save()
        Logger.lyrics.debug(
            "Persisted lyrics — songId=\(resolvedSongID, privacy: .public) enhanced=\(fetchedWithEnhanced, privacy: .public)"
        )
    }
}
