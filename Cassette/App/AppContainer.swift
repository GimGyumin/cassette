// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// DI root. Creates and wires all services in dependency order.
/// Passed into the SwiftUI environment via \.appContainer.
/// All stored service references are protocol existentials — fully mockable in tests.
@MainActor
final class AppContainer {
    // Observable state objects — created here so they exist on the MainActor
    // before actors are initialized (actors receive them via init injection).
    let playerState = PlayerState()
    let serverState = ServerState()
    let cacheSettings = CacheSettings()
    let streamingSettings = StreamingSettings()

    let modelContainer: ModelContainer
    /// CloudKit-backed store for listening history (Wrapped / stats). Isolated from downloads/cache.
    let listeningModelContainer: ModelContainer
    let keychainService: any KeychainServiceProtocol
    let mediaIdentityService: MediaIdentityService
    let mediaIdentityReconciliationService: MediaIdentityReconciliationService
    let jellyfinService: JellyfinService
    let jellyfinDiscoveryService = JellyfinLANDiscoveryService()
    let serverService: any ServerServiceProtocol
    let libraryService: any LibraryServiceProtocol
    let cacheService: any CacheServiceProtocol
    let downloadService: any DownloadServiceProtocol
    let mediaResolver: any MediaResolverProtocol
    let playerService: any PlayerServiceProtocol
    let nowPlayingService: any NowPlayingServiceProtocol
    let favoritesService: any FavoritesServiceProtocol
    let pinService: any PinServiceProtocol
    let playlistService: any PlaylistServiceProtocol
    let radioService: any RadioServiceProtocol
    let toastService = ToastService()
    let networkMonitor = NetworkMonitor()
    /// Whether the **active server** (not just the device) is answering. Started by `CassetteApp`
    /// once the container is published, alongside `networkMonitor`.
    let serverReachabilityMonitor: ServerReachabilityMonitor
    let sessionService: PlaybackSessionService
    let dominantColorExtractor = DominantColorExtractor()
    let artworkImageCache: ArtworkImageCache
    let statsService: StatsService
    private let _player: PlayerService
    let wrappedPlaylistService: WrappedPlaylistService
    let lyricsService: LyricsService
    let widgetSyncService: WidgetSyncService
    let recommendationService: RecommendationService
    let personalMixService: PersonalMixService
    let listenBrainzService: ListenBrainzService
    let externalProvidersStore = ExternalProvidersStore()
    let externalArtworkCache = ExternalArtworkCache()
    let externalArtistImageResolver = ExternalArtistImageResolver()
    let searchHistoryService: SearchHistoryService
    let libraryIndexService: LibraryIndexService
    /// Owns the iOS Live Activity shown while a preparation pass runs. Inert on macOS.
    let libraryPreparationLiveActivity = LibraryPreparationLiveActivityController()
    let libraryPreparationService: LibraryPreparationService
    let replayGainService = ReplayGainService()
    let replayGainSettings = ReplayGainSettings()
    let crossfadeSettings = CrossfadeSettings()
    let gaplessSettings = GaplessSettings()
    let storageManagementService: StorageManagementService
    let albumCoverPreloadService: AlbumCoverPreloadService
    /// Measures the link once per server so "Automatic" quality/route can adapt on a slow cellular
    /// connection without probing on every track.
    let networkSpeedProbe = NetworkSpeedProbe()

    /// `engine` exists so tests can drive a real `PlayerService` with a fake audio engine: the
    /// composition root is otherwise the only place that knows the concrete engine.
    init(inMemory: Bool = false, engine: (any PlaybackEngine)? = nil) throws {
        libraryIndexService = LibraryIndexService(
            serverID: { [serverState] in serverState.activeServer?.id },
            networkAvailable: { [serverState] in serverState.isOnline && serverState.isServerReachable },
            directory: inMemory ? nil : LibraryIndexService.defaultDirectory
        )
        modelContainer = try ModelContainer.cassette(inMemory: inMemory)
        listeningModelContainer = try ModelContainer.listening(inMemory: inMemory)
        sessionService = PlaybackSessionService(modelContainer: try ModelContainer.session(inMemory: inMemory))

        Self.migratePlaybackEventsIfNeeded(from: modelContainer, to: listeningModelContainer)

        let keychain = KeychainService()
        keychainService = keychain
        mediaIdentityService = MediaIdentityService(modelContainer: modelContainer)

        let cache = CacheService(
            modelContainer: modelContainer,
            maxBytes: cacheSettings.maxCacheBytes,
            mediaIdentityService: mediaIdentityService
        )
        cacheService = cache

        let stats = StatsService(modelContainer: listeningModelContainer)
        statsService = stats

        let server = ServerService(state: serverState, keychain: keychain, modelContainer: modelContainer, cacheService: cache)
        serverService = server
        // One bounded `ping` — no retries (the client builds with `retryPolicy: .none`) — is enough
        // to tell "the device has a route" apart from "the server answers", which is what the
        // server-backed tabs need to know.
        serverReachabilityMonitor = ServerReachabilityMonitor(
            serverState: serverState,
            probe: { try await server.testConnection() }
        )
        let jellyfinDeviceIdentity = JellyfinDeviceIdentity.current()
        jellyfinService = JellyfinService(
            serverService: server,
            keychain: keychain,
            modelContainer: modelContainer,
            deviceIdentity: jellyfinDeviceIdentity
        )
        lyricsService = LyricsService(
            serverService: server,
            modelContainer: modelContainer,
            mediaIdentityService: mediaIdentityService
        )
        wrappedPlaylistService = WrappedPlaylistService(serverService: server, statsService: stats)
        radioService = RadioService(serverService: server)

        let download = DownloadService(
            serverService: server,
            modelContainer: modelContainer,
            toastService: toastService,
            mediaIdentityService: mediaIdentityService,
            jellyfinService: jellyfinService
        )
        downloadService = download

        let library = LibraryService(serverService: server, modelContainer: modelContainer, downloadService: download, statsService: stats)
        libraryService = library
        mediaIdentityReconciliationService = MediaIdentityReconciliationService(
            modelContainer: modelContainer,
            libraryService: library,
            identityService: mediaIdentityService
        )

        artworkImageCache = ArtworkImageCache(downloadService: download, libraryService: library, serverService: server)

        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — cannot initialise AppContainer")
        }
        // Shared knowledge, computed once: the bulk cover pass probes this directory to see what a
        // previous run already wrote, and WidgetSyncService copies covers out of it.
        let coversDir = docs.appendingPathComponent("app.cassette/coverarts", isDirectory: true)

        albumCoverPreloadService = AlbumCoverPreloadService(
            libraryService: library,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: dominantColorExtractor,
            playerState: playerState,
            serverState: serverState,
            coversDirectory: coversDir,
            songCoverProvider: { [libraryIndexService] in
                await libraryIndexService.ensureIndexedAndWait(using: library)
                guard libraryIndexService.lastIndexedAt != nil else { throw CassetteError.timeout }
                return libraryIndexService.songArtworkSnapshot
            }
        )

        storageManagementService = StorageManagementService(
            modelContainer: modelContainer,
            cacheService: cache,
            downloadService: download,
            externalArtworkCache: externalArtworkCache,
            artworkImageCache: artworkImageCache,
            dominantColorExtractor: dominantColorExtractor,
            albumCoverPreloadService: albumCoverPreloadService
        )

        let resolver = MediaResolver(
            downloadService: download,
            cacheService: cache,
            serverService: server,
            serverState: serverState,
            streamingSettings: streamingSettings,
            mediaIdentityService: mediaIdentityService,
            jellyfinService: jellyfinService,
            speedProbe: networkSpeedProbe
        )
        mediaResolver = resolver

        let lbClient = ListenBrainzClient(transport: URLSessionListenBrainzTransport())
        let lb = ListenBrainzService(client: lbClient, keychain: keychain)
        listenBrainzService = lb

        let player = PlayerService(state: playerState, mediaResolver: resolver, serverService: server, sessionService: sessionService, artworkImageCache: artworkImageCache, lyricsService: lyricsService, libraryService: library, cacheService: cache, downloadService: download, cacheSettings: cacheSettings, streamingSettings: streamingSettings, replayGainSettings: replayGainSettings, crossfadeSettings: crossfadeSettings, gaplessSettings: gaplessSettings, toastService: toastService, statsService: stats, listenBrainzService: lb, jellyfinService: jellyfinService, engine: engine ?? AudioStreamingPlayerEngine())
        _player = player
        playerService = player

        let coverPreloadForNowPlaying = albumCoverPreloadService
        let nowPlaying = NowPlayingService(
            playerService: player,
            artworkImageCache: artworkImageCache,
            serverState: serverState,
            preparedCoverIdProvider: { albumId in coverPreloadForNowPlaying.preparedCoverArtId(forAlbumId: albumId) }
        )
        nowPlayingService = nowPlaying

        favoritesService = FavoritesService(
            libraryService: library,
            serverState: serverState,
            modelContainer: modelContainer,
            mediaIdentityService: mediaIdentityService
        )
        let pin = PinService(modelContainer: modelContainer)
        pinService = pin
        let playlist = PlaylistService(serverService: server, modelContainer: modelContainer, downloadService: download)
        playlistService = playlist

        let widgetSync = WidgetSyncService(
            dominantColorExtractor: dominantColorExtractor,
            modelContainer: modelContainer,
            artworkCache: artworkImageCache,
            coversDirectory: coversDir,
            serverState: serverState
        )
        widgetSyncService = widgetSync
        pin.setWidgetSyncService(widgetSync)
        // Any activity left over from a previous run would otherwise sit on the lock screen forever.
        let preparationArtwork = PreparationArtworkStore(cache: artworkImageCache)
        libraryPreparationLiveActivity.artworkProvider = { id in await preparationArtwork.prepare(coverID: id) }
        libraryPreparationLiveActivity.reconcileOnLaunch()
        #if os(iOS)
        // ActivityKit only *starts* an activity from the foreground, so the controller is told when
        // that is true rather than importing UIKit into the Services layer.
        libraryPreparationLiveActivity.isAppActive = {
            UIApplication.shared.applicationState == .active
        }
        #endif
        // Progress publisher for the in-app preparation screen and the iOS Live Activity. The
        // background window is opportunistic: iOS decides when a `BGProcessingTask` runs, and such a
        // pass may only *update* an activity it did not start.
        libraryPreparationService = LibraryPreparationService(
            liveActivity: libraryPreparationLiveActivity,
            serverName: { [serverState] in serverState.activeServer?.displayName ?? "" },
            requestBackgroundContinuation: {
                #if os(iOS)
                CassetteApp.scheduleLibraryPreparation()
                #endif
            }
        )
        // The full cover download is the one pass that also runs outside this service — onboarding's
        // first download, the launch-time resume, and the manual download in storage settings. It
        // reports through the same entry point so all of them share the screen and the Live Activity.
        albumCoverPreloadService.reportPreparation = { [libraryPreparationService] snapshot in
            libraryPreparationService.receiveExternalProgress(snapshot)
        }
        albumCoverPreloadService.requestBackgroundContinuation = {
            #if os(iOS)
            CassetteApp.scheduleLibraryPreparation()
            #endif
        }

        NowPlayingBridge.performTogglePlayPause = { [weak player] in await player?.togglePlayPause() }

        if #available(iOS 27.0, macOS 27.0, *) {
            SiriBridge.playbackProvider = { [playerService] in playerService }
            SiriBridge.favoritesProvider = { [favoritesService] in favoritesService }
            SiriBridge.playlistProvider = { [playlistService] in playlistService }
            SiriBridge.openURLAction = { url in
                #if os(iOS)
                await MainActor.run { UIApplication.shared.open(url) }
                #endif
            }
        }

        let subsonicProvider = SubsonicRecommendationProvider(libraryService: library)
        let lbProvider = ListenBrainzRecommendationProvider(client: lbClient, service: lb, libraryService: library)
        recommendationService = RecommendationService(providers: [lbProvider, subsonicProvider])
        personalMixService = PersonalMixService(libraryService: library, statsService: stats)

        searchHistoryService = SearchHistoryService(container: modelContainer)

        // Siri / Apple Intelligence catalog — iOS 27 only. Kept out of the
        // stored-property list because the types are availability-gated; the
        // bridge closure retains the catalog (and its metadata store) directly.
        if #available(iOS 27.0, macOS 27.0, *) {
            let metadataStore = LibraryMetadataStore(modelContainer: modelContainer)
            let catalog = SiriCatalogService(
                libraryService: library,
                metadataStore: metadataStore,
                libraryIndex: libraryIndexService,
                serverState: serverState,
                mediaIdentityService: mediaIdentityService
            )
            SiriBridge.catalogProvider = { [catalog] in catalog }
        }

        // Defer non-critical disk/network work so it can't race Home's first paint.
        Task(priority: .utility) { [playlist] in
            await AppBootGate.waitForHome()
            await playlist.retryMissingPlaylistDownloads()
        }
        Task(priority: .utility) {
            await AppBootGate.waitForHome()
            await listenBrainzService.loadPersistedState()
        }
        // Library index rebuild is deferred to Search first use — avoid allAlbums(500)
        // contending with Home covers / soft-refresh / personal mixes.
        Task(priority: .background) {
            await externalArtworkCache.runGarbageCollection()
        }
        Task(priority: .background) { [mediaIdentityReconciliationService, jellyfinService, serverState] in
            await AppBootGate.waitForHome()
            guard let serverID = await MainActor.run(body: { serverState.activeServer?.id }) else { return }
            _ = await jellyfinService.capabilities()
            await mediaIdentityReconciliationService.reconcileDownloads(serverID: serverID)
        }
    }

    /// Awaited by CassetteApp's `.task` before the UI appears, ensuring
    /// PlayerService→NowPlayingService and PlayerService→WidgetSyncService
    /// wiring is complete before any user interaction is possible.
    func setup() async {
        await _player.setNowPlayingService(nowPlayingService)
        await _player.setWidgetSyncService(widgetSyncService)
        await _player.setReplayGainService(replayGainService)
        await _player.crossfadeSettingsDidChange()
        await _player.gaplessSettingsDidChange()
        // Register MPRemoteCommandCenter before Siri or background playback can begin.
        // Waiting for Home/session restoration leaves a cold Siri launch without a fully
        // initialized Now Playing session, so Apple Watch sees stale or empty metadata.
        await nowPlayingService.start()
    }

    /// Call after the user re-enters a missing Keychain password so cached API clients
    /// don't keep failing with `credentialsMissing`.
    func invalidateAPIClientsAfterCredentialChange() async {
        await libraryService.invalidateClientCache()
        await playlistService.invalidateClientCache()
        await radioService.invalidateClientCache()
        DiscoverSectionsCache.clear()
        libraryIndexService.rebuild(using: libraryService)
        albumCoverPreloadService.reconcileChangedCovers()
        if #available(iOS 27.0, macOS 27.0, *) {
            await warmSiriLibrary()
        }
    }

    /// Warms the Siri catalog (song store + Spotlight index) once per server so the
    /// first Siri request on a fresh install / fresh login can resolve entities.
    @available(iOS 27.0, macOS 27.0, *)
    func warmSiriLibrary() async {
        await SiriBridge.catalogProvider?()?.warmLibraryForSiri()
    }

    /// Rebuilds the in-memory library index (artists/albums/playlists) and warms the
    /// Siri catalog. The onboarding preparation screen drives this and shows progress
    /// via libraryIndexService.progress.
    @discardableResult
    func indexLibraryForOnboarding() async -> Bool {
        let ready = await libraryIndexService.rebuildAndWait(using: libraryService)
        guard ready else { return false }
        if #available(iOS 27.0, macOS 27.0, *) {
            await warmSiriLibrary()
        }
        return true
    }

    /// Each track may carry distinct embedded artwork, even within one album.
    func playbackCoverId(for song: DisplayableSong?) -> String? {
        song?.effectiveCoverArtId
    }

    /// Album-id → prepared cover id, for surfaces that only carry the album id (lock screen).
    /// Returns nil when the album was never prepared, so callers fall back to the song's own id.
    func preparedCoverId(forAlbumId albumId: String?) -> String? {
        guard let prepared = albumCoverPreloadService.preparedCoverArtId(forAlbumId: albumId)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prepared.isEmpty else { return nil }
        return prepared
    }

    /// Developer / diagnostics UserDefaults keys (in-app Settings buttons).
    enum DeveloperSettingsKey {
        /// When true, OnboardingView must not auto-skip for an existing server.
        static let forceOnboardingReplay = "cassette.debug.forceOnboardingReplay"
    }

    /// Clears ephemeral caches (audio, lyrics, artwork memory, descriptions, translations).
    /// Does **not** remove offline downloads or server credentials.
    func resetAllCachedData() async {
        await cacheService.clearAll()
        await DescriptionCache.shared.clear()
        TranslationCache.shared.clear()
        await storageManagementService.clearArtworkCaches()
        await storageManagementService.clear(.discover)
        Logger.boot.info("Developer: reset all cached data")
        toastService.showSuccess(String(localized: "Cached data cleared", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    /// Clears all caches, streaming artwork tiers, and resets in-app preferences to defaults.
    /// Does **not** remove servers, credentials, listening stats, or search history.
    func resetCachesAndAppSettings() async {
        await cacheService.clearAudioTracksOnly()
        await cacheService.clearLyricsCache()
        await storageManagementService.clear(.descriptions)
        await storageManagementService.clear(.translations)
        await storageManagementService.clear(.discover)
        await storageManagementService.clearArtworkCaches()
        URLCache.shared.removeAllCachedResponses()
        resetAppSettingsToDefaults()
        Logger.boot.info("Reset caches and app settings")
        toastService.showSuccess(String(localized: "Cache and settings reset", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    @MainActor
    private func resetAppSettingsToDefaults() {
        let defaults = UserDefaults.standard
        let keys = [
            "cassette.cache.maxTracks",
            "cassette.cache.maxMegabytes",
            "cassette.cache.format",
            "cassette.cache.cellular",
            "cassette.streaming.wifi",
            "cassette.streaming.cellular",
            "cassette.streaming.download",
            "cassette.download.automaticAfterStreaming",
            "cassette.download.automaticOverCellular",
            "cassette.lyrics.largerText",
            "cassette.visuals.animatedArtwork",
            BulkArtworkPreference.key,
            IntegrationIntroPreference.listenBrainzKey,
            IntegrationIntroPreference.externalAppsKey,
            "cassette.history.enabled",
            "cassette.replayGain.enabled",
            "cassette.replayGain.mode",
            "cassette.replayGain.preAmp",
            "cassette.replayGain.preventClipping",
            "cassette.crossfade.duration",
            "cassette.crossfade.disableForGapless",
            GaplessSettings.enabledKey,
            AppleMusicSettings.enrichKey,
            AppleMusicSettings.hapticsKey,
            AppleMusicSettings.hapticsIntensityKey,
            "isTranslationEnabled",
            "isAutoTranslateEnabled",
            "translationProvider",
            "targetLanguage",
            "translationStrategyPreference",
            "openAIAPIKey",
            LyricsSourcePreference.userDefaultsKey,
            "cassette.player.autoExtendEnabled",
            "cassette.dominantColor.cache.v8",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        LyricsTranslationSettings.registerDefaults()
        AppleMusicSettings.registerDefaults()
        cacheSettings.reloadFromDefaults()
        streamingSettings.reloadFromDefaults()
        replayGainSettings.reloadFromDefaults()
        crossfadeSettings.reloadFromDefaults()
        gaplessSettings.reloadFromDefaults()
        LyricsTranslationSettings.shared.reloadFromDefaults()
        AppleMusicSettings.shared.reloadFromDefaults()
        #if os(iOS)
        MusicHapticsController.shared.refresh()
        #endif
        Task {
            await cacheService.setMaxBytes(cacheSettings.maxCacheBytes)
            await playerService.replayGainSettingsDidChange()
            await playerService.crossfadeSettingsDidChange()
            await playerService.gaplessSettingsDidChange()
        }
    }

    /// Wipes every saved server + Keychain credentials, then re-opens the full onboarding
    /// flow (including Apple Account–style sign-in). Offline downloads are left alone.
    func replayOnboarding() async {
        await playerService.stop()

        #if canImport(UIKit)
        await MainActor.run {
            _ = UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
        #endif

        let serverIds = serverState.servers.map(\.id)
        for id in serverIds {
            do {
                try await serverService.removeServer(id: id)
            } catch {
                Logger.boot.error(
                    "Developer replay: failed to remove server \(id.uuidString, privacy: .public) — \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        await invalidateAPIClientsAfterCredentialChange()

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DeveloperSettingsKey.forceOnboardingReplay)
        defaults.set(false, forKey: "onboardingComplete")
        Logger.boot.info("Developer: wiped \(serverIds.count, privacy: .public) server(s) and replaying onboarding")
    }
}

// MARK: - CloudKit

nonisolated enum CassetteCloudKit {
    static let containerIdentifier = "iCloud.com.kyumin.Music.Cassette"
}

// MARK: - ModelContainer factory

extension ModelContainer {
    /// Flip to `true` only after joining the Apple Developer Program and restoring iCloud/CloudKit
    /// entitlements — Personal Teams cannot provision iCloud.
    private static let isCloudKitSyncEnabled = false

    private static func cloudKitDatabase(inMemory: Bool) -> ModelConfiguration.CloudKitDatabase {
        guard isCloudKitSyncEnabled, !inMemory else { return .none }
        return .private(CassetteCloudKit.containerIdentifier)
    }

    /// Creates the Cassette ModelContainer.
    /// - Parameter inMemory: Pass `true` in tests — Swift Testing parallelises tests,
    ///   so each test must create its own in-memory container (never shared).
    ///
    /// Opening a persistent store is deliberately non-destructive. A transient failure such as
    /// a full disk or temporary file lock must never be interpreted as permission to erase data.
    static func cassette(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            ServerConfig.self,
            CachedTrack.self,
            DownloadedTrack.self,
            DownloadedAlbum.self,
            DownloadedPlaylist.self,
            QueueSnapshot.self,
            FavoriteRecord.self,
            PinnedItem.self,
            PlaybackSession.self, // kept for schema-mismatch migration safety; see session() below
            PlaybackEvent.self,   // kept for migration into listening(); see listening() below
            CachedLyrics.self,
            SearchHistoryEntry.self,
            LibraryMetadataSong.self,
            PlaylistCoverChoice.self,
            RemoteIDAlias.self,
            RemoteMediaIdentity.self,
            JellyfinCapabilityRecord.self
        ])
        // Local-only: downloads/cache/favorites must not sync via iCloud.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try openStore(named: "default", schema: schema, configuration: config)
    }

    /// Opens a store and preserves it on failure so the app can offer an explicit recovery choice.
    private static func openStore(
        named name: String,
        schema: Schema,
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Logger.boot.error(
                "SwiftData store '\(name, privacy: .public)' failed to open; preserving files: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Removes the store file plus `-shm` / `-wal` sidecars used by SQLite.
    private static func removeSwiftDataStoreFiles(at url: URL) {
        let fm = FileManager.default
        for candidate in [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal")
        ] {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            do {
                try fm.removeItem(at: candidate)
            } catch {
                Logger.boot.error(
                    "Failed to remove SwiftData file \(candidate.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Explicit last-resort wipe of all Cassette SwiftData files (main + session + listening).
    /// Call only after the user confirms the destructive recovery action.
    static func resetAllCassetteStores() {
        let configs: [ModelConfiguration] = [
            ModelConfiguration(isStoredInMemoryOnly: false),
            ModelConfiguration("cassette-session", isStoredInMemoryOnly: false),
            ModelConfiguration("cassette-listening", isStoredInMemoryOnly: false)
        ]
        for config in configs {
            removeSwiftDataStoreFiles(at: config.url)
        }
        Logger.boot.warning("Reset all Cassette SwiftData store files")
    }

    /// CloudKit-backed store for `PlaybackEvent` (Wrapped / listening history).
    ///
    /// Isolated so downloads and cache stay device-local. `PlaybackEvent` remains in
    /// `cassette()` only for one-time migration from older installs.
    static func listening(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([PlaybackEvent.self])
        do {
            let config = ModelConfiguration(
                "cassette-listening",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase(inMemory: inMemory)
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Portal / entitlement misconfig should not brick the app — fall back to local store.
            Logger.boot.error("CloudKit listening store unavailable, using local-only: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(
                "cassette-listening",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
            return try openStore(named: "cassette-listening", schema: schema, configuration: config)
        }
    }

    /// Isolated container for playback session data (queue + position), synced via CloudKit.
    ///
    /// Separating PlaybackSession from the main container means
    /// PlaybackSessionService.savePosition() (every 5 s during playback) no longer
    /// posts change notifications to the main store coordinator. The main context's
    /// @Query<SearchHistoryEntry> never sees these saves, eliminating the continuous
    /// 5-second render cascade that previously fired during all active playback.
    ///
    /// PlaybackSession.self is retained in cassette() purely to avoid a schema-mismatch
    /// migration error when opening existing stores from app versions where it lived
    /// in the main container. That table remains in the main store file but is never
    /// written to after this change.
    /// - Parameter inMemory: Pass `true` in tests.
    static func session(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([PlaybackSession.self])
        do {
            let config = ModelConfiguration(
                "cassette-session",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudKitDatabase(inMemory: inMemory)
            )
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            Logger.boot.error("CloudKit session store unavailable, using local-only: \(error.localizedDescription, privacy: .public)")
            let config = ModelConfiguration(
                "cassette-session",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
            return try openStore(named: "cassette-session", schema: schema, configuration: config)
        }
    }
}

// MARK: - Listening history migration

extension AppContainer {
    private static let listeningEventsMigratedKey = "cassette.listeningEventsMigrated.v1"

    /// Copies legacy `PlaybackEvent` rows from the main store into the CloudKit listening store once.
    static func migratePlaybackEventsIfNeeded(from main: ModelContainer, to listening: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: listeningEventsMigratedKey) else { return }

        let source = ModelContext(main)
        let destination = ModelContext(listening)
        let descriptor = FetchDescriptor<PlaybackEvent>()
        guard let legacy = try? source.fetch(descriptor), !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: listeningEventsMigratedKey)
            return
        }

        let existingIDs = Set(((try? destination.fetch(descriptor)) ?? []).map(\.id))
        var migrated = 0
        for event in legacy where !existingIDs.contains(event.id) {
            destination.insert(
                PlaybackEvent(
                    id: event.id,
                    trackId: event.trackId,
                    trackTitle: event.trackTitle,
                    albumId: event.albumId,
                    albumTitle: event.albumTitle,
                    artistId: event.artistId,
                    artistName: event.artistName,
                    genre: event.genre,
                    timestamp: event.timestamp,
                    durationListened: event.durationListened,
                    trackDuration: event.trackDuration,
                    wasCompleted: event.wasCompleted,
                    serverId: event.serverId
                )
            )
            migrated += 1
        }

        do {
            try destination.save()
            UserDefaults.standard.set(true, forKey: listeningEventsMigratedKey)
            Logger.stats.info("Migrated \(migrated, privacy: .public) playback events into CloudKit listening store")
        } catch {
            Logger.stats.error("Failed to migrate playback events: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Cover art cache invalidation

extension AppContainer {
    private static let coverArtCacheVersionKey = "cassette.coverArtCacheVersion"
    private static let currentCoverArtCacheVersion = 5

    /// Purges cover art files from disk on the first launch after a cache format change,
    /// so stale files don't shadow the new decode pipeline. Version history:
    ///   v5 — ArtworkImageCache now decodes at 240 px (thumb) / 1200 px (full) via
    ///         CGImageSourceCreateThumbnailAtIndex; legacy full-res files cause ~800 ms
    ///         decodes on cold open even after the code fix — wipe forces a clean re-download.
    ///   v4 and earlier — previous resolution bumps.
    static func invalidateCoverArtCacheIfNeeded(artworkCache: ArtworkImageCache) {
        let stored = UserDefaults.standard.integer(forKey: coverArtCacheVersionKey)
        guard stored < currentCoverArtCacheVersion else { return }

        artworkCache.clearCache()
        let coverArtsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.cassette/coverarts")
        try? FileManager.default.removeItem(at: coverArtsDir)
        try? FileManager.default.createDirectory(at: coverArtsDir, withIntermediateDirectories: true)
        URLCache.shared.removeAllCachedResponses()

        UserDefaults.standard.set(currentCoverArtCacheVersion, forKey: coverArtCacheVersionKey)
        Logger.player.info("ArtworkImageCache: invalidated cover art disk cache (version \(stored) → \(currentCoverArtCacheVersion))")
    }
}

// MARK: - Legacy cover art sweep

extension AppContainer {
    private static let artworkLegacySweepKey = "cassette.artworkLegacySweep_v2"

    /// One-shot background sweep that deletes untagged cover art files written by
    /// pre-tier builds (plain `{id}` filenames with no `@thumb` / `@hero` suffix).
    ///
    /// These full-res JPEGs can be 2–4 MB each; decoding them at the 240px thumb
    /// size took ~1100ms per file on a background thread, starving the audio decode
    /// thread and causing audible crackling during queue load. ArtworkImageCache no
    /// longer reads them (since the legacy fallback was removed), but they still
    /// waste disk space and could confuse future disk-hit logic. Deleting them here
    /// forces a clean re-download at the correct tier size.
    static func sweepLegacyCoverArtFiles() {
        // Untagged files can be the only offline cover. Original and legacy downloads are retained.
        UserDefaults.standard.set(true, forKey: artworkLegacySweepKey)
    }

}

// MARK: - Audio extension migration

extension AppContainer {
    private static let audioExtMigrationKey = "cassette.audioExtMigration_v1"

    /// One-shot migration that fixes downloaded tracks saved with a `.mpeg` extension.
    ///
    /// Root cause: the original DownloadService derived the file extension from the HTTP
    /// Content-Type header. `audio/mpeg` → `.mpeg`, which AVPlayer maps to a video UTI
    /// (public.mpeg) instead of public.mp3, causing silent playback failure for MP3 files.
    ///
    /// This migration:
    /// 1. Purges the ephemeral CacheService (all entries may carry .mpeg).
    /// 2. Renames permanent downloaded files from .mpeg to the correct extension using
    ///    the server-declared `suffix` stored in DownloadedTrack, falling back to a
    ///    MIME-type map when suffix is absent.
    /// 3. Updates the SwiftData filePath records for each successfully renamed file.
    static func migrateAudioExtensionsIfNeeded(
        modelContainer: ModelContainer,
        cacheService: any CacheServiceProtocol
    ) async {
        guard !UserDefaults.standard.bool(forKey: audioExtMigrationKey) else { return }

        await cacheService.clearAll()
        Logger.migration.info("[ExtMigration] Ephemeral audio cache cleared")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDir = docs.appendingPathComponent("app.cassette/downloads", isDirectory: true)

        let ctx = ModelContext(modelContainer)
        let tracks = (try? ctx.fetch(FetchDescriptor<DownloadedTrack>())) ?? []

        var renamedCount = 0
        var skippedCount = 0

        for track in tracks {
            guard track.filePath.hasSuffix(".mpeg") else { continue }
            let desiredExt: String
            if let s = track.suffix, !s.isEmpty {
                desiredExt = s
            } else {
                desiredExt = Self.audioExtFromMime(track.mimeType)
            }
            guard desiredExt != "mpeg" else { continue }

            let oldPath = track.filePath
            let newPath = String(oldPath.dropLast(".mpeg".count)) + ".\(desiredExt)"
            let oldURL = downloadsDir.appendingPathComponent(oldPath)
            let newURL = downloadsDir.appendingPathComponent(newPath)

            guard FileManager.default.fileExists(atPath: oldURL.path) else {
                Logger.migration.warning("[ExtMigration] File missing, skipping: '\(oldPath, privacy: .public)'")
                skippedCount += 1
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                track.filePath = newPath
                renamedCount += 1
                Logger.migration.info("[ExtMigration] '\(oldPath, privacy: .public)' → '\(newPath, privacy: .public)'")
            } catch {
                Logger.migration.error("[ExtMigration] Rename failed '\(oldPath, privacy: .public)': \(error, privacy: .public)")
                skippedCount += 1
            }
        }

        try? ctx.save()
        UserDefaults.standard.set(true, forKey: audioExtMigrationKey)
        Logger.migration.info("[ExtMigration] Complete: \(renamedCount) renamed, \(skippedCount) skipped")
    }

    // v3: v2 was burned on installs that ran it against an EMPTY download set (fresh install) —
    // it set the done-flag on a clean-but-empty pass, so the scan→remux path was never exercised.
    // The version bump re-runs the migration; both keys bump together so the attempt counter resets.
    private static let m4aFaststartMigrationKey = "cassette.m4aFaststartMigration_v3"
    private static let m4aFaststartAttemptsKey = "cassette.m4aFaststartMigration_v3_attempts"
    private static let m4aFaststartMaxAttempts = 3

    /// Migration that faststart-remuxes already-downloaded m4a tracks so they play offline through
    /// AudioStreaming (which cannot open non-faststart M4A). Fire-and-forget at boot.
    ///
    /// Retry-safe (unlike v1): the done-flag is set ONLY on a clean pass — save succeeded AND no
    /// track failed to remux. Failed tracks (e.g. a transient export failure at boot) are retried
    /// on the next launch, up to `m4aFaststartMaxAttempts` passes, after which it gives up so a
    /// genuinely irrecoverable file can't trigger an eternal boot-time retry.
    ///
    /// Detection is CONTENT-based (`ftyp` sniff), not extension-based, so a mis-served m4a that an
    /// earlier migration renamed `.mp3` is still caught. A remux REWRITES the bytes, so
    /// `DownloadedTrack.fileSize` is refreshed from the remuxed file (with the same `?? 0` fallback
    /// as the download path, so `downloadedURL`'s `fileSize == 0` escape covers a size-read miss
    /// instead of persisting a stale, mismatched size). Scope: DownloadedTrack only (CachedTrack = Phase 2).
    static func migrateM4AFaststartIfNeeded(modelContainer: ModelContainer) async {
        guard !UserDefaults.standard.bool(forKey: m4aFaststartMigrationKey) else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsDir = docs.appendingPathComponent("app.cassette/downloads", isDirectory: true)

        let ctx = ModelContext(modelContainer)
        let tracks = (try? ctx.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        let remuxer = AudioFaststartRemuxer()

        var remuxedCount = 0
        var failedCount = 0
        var m4aCount = 0
        for track in tracks {
            let fileURL = downloadsDir.appendingPathComponent(track.filePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            // Content sniff, not extension — catches a container with a wrong/renamed extension.
            guard AudioFaststartRemuxer.isM4AContainer(atPath: fileURL.path) else { continue }
            m4aCount += 1
            switch await remuxer.remuxToFaststartIfNeeded(at: fileURL) {
            case .remuxed:
                // Bytes changed — refresh fileSize from the remuxed file (?? 0 mirrors the
                // download path, where downloadedURL's `== 0` escape tolerates a read miss).
                let newSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                track.fileSize = newSize
                remuxedCount += 1
                Logger.migration.info("[M4AFaststart] faststart-remuxed '\(track.songId, privacy: .public)'")
            case .failed:
                failedCount += 1
                Logger.migration.warning("[M4AFaststart] export failed '\(track.songId, privacy: .public)' — will retry next boot")
            case .skipped:
                break   // already faststart or not an MP4 container — nothing to do
            }
        }

        // Persist the fileSize updates; only mark done on a clean pass so failures are retried.
        var saveOK = true
        do {
            try ctx.save()
        } catch {
            saveOK = false
            Logger.migration.error("[M4AFaststart] save failed: \(error, privacy: .public) — not marking done, will retry")
        }

        let attempts = UserDefaults.standard.integer(forKey: m4aFaststartAttemptsKey) + 1
        UserDefaults.standard.set(attempts, forKey: m4aFaststartAttemptsKey)
        let giveUp = attempts >= m4aFaststartMaxAttempts
        if saveOK && (failedCount == 0 || giveUp) {
            UserDefaults.standard.set(true, forKey: m4aFaststartMigrationKey)
            if failedCount > 0 {
                Logger.migration.warning("[M4AFaststart] giving up after \(attempts) attempts with \(failedCount) still failing")
            }
        }
        Logger.migration.info("[M4AFaststart] Complete: \(remuxedCount) remuxed, \(failedCount) failed of \(m4aCount) m4a (\(tracks.count) total), attempt \(attempts)")
    }

    private static func audioExtFromMime(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3":        return "mp3"
        case "audio/flac", "audio/x-flac":     return "flac"
        case "audio/mp4", "audio/m4a",
             "audio/aac", "audio/x-aac":       return "m4a"
        case "audio/ogg":                       return "ogg"
        case "audio/opus":                      return "opus"
        case "audio/wav", "audio/x-wav":       return "wav"
        case "audio/aiff", "audio/x-aiff":     return "aiff"
        case "audio/eac3", "audio/ec3", "audio/ac3": return "ec3"
        default:                                return "mpeg"
        }
    }
}

// MARK: - SwiftUI environment key

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue: AppContainer? = nil
}

extension EnvironmentValues {
    var appContainer: AppContainer? {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
