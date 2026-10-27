// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import OSLog
import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@main
struct CassetteApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CassetteAppDelegate.self) private var appDelegate
    #endif

    @State private var container: AppContainer?
    @State private var bootFailureMessage: String?
    @State private var bootAttempt = 0
    @State private var chromeAppearance = ChromeAppearance()
    @AppStorage(AppUILanguage.storageKey) private var appLanguageCode = ""
    @Environment(\.scenePhase) private var scenePhase

    // Background handlers read these dependencies only after hopping to MainActor.
    #if os(iOS)
    @MainActor private static var _bgTaskService: WrappedPlaylistService?
    @MainActor private static var _bgTaskServerState: ServerState?
    /// Set once the container exists. Runs one library-preparation pass when iOS grants a
    /// background window, which is the only way a long cover pass can continue off-screen.
    @MainActor private static var _bgLibraryPreparation: (@MainActor () async -> Void)?
    #endif

    init() {
        RuntimeDiagnostics.mark(.appInit)
        // Start the battery / thermal policy before the first view body runs, so no frame is ever
        // rendered with the placeholder budget.
        PerformanceGovernor.shared.start()
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "app.cassette.wrapped.monthly-update",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let workTask = Task { @MainActor in
                defer { processingTask.expirationHandler = nil }
                guard !Task.isCancelled, let service = CassetteApp._bgTaskService,
                      let serverId = CassetteApp._bgTaskServerState?.activeServer?.id.uuidString else {
                    processingTask.setTaskCompleted(success: false)
                    return
                }
                let result = await service.runYearlyPlaylistSyncIfNeeded(serverId: serverId, calendar: .current)
                Logger.wrapped.info("BGTask result: \(String(describing: result), privacy: .public)")
                processingTask.setTaskCompleted(success: !Task.isCancelled)
                CassetteApp.scheduleWrappedUpdate()
            }
            processingTask.expirationHandler = {
                workTask.cancel()
                Logger.wrapped.warning("BGTask expired — rescheduling for tomorrow")
                CassetteApp.scheduleWrappedUpdate()
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "app.cassette.library.preparation",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                CassetteApp.scheduleLibraryPreparation()
                return
            }
            // The pass is resumable (covers check the disk first), so an expiring window still
            // leaves the work in a consistent state; the next window picks up where this stopped.
            let workTask = Task { @MainActor in
                defer { processingTask.expirationHandler = nil }
                guard !Task.isCancelled, let prepare = CassetteApp._bgLibraryPreparation else {
                    processingTask.setTaskCompleted(success: false)
                    CassetteApp.scheduleLibraryPreparation()
                    return
                }
                await prepare()
                processingTask.setTaskCompleted(success: !Task.isCancelled)
                if Task.isCancelled { CassetteApp.scheduleLibraryPreparation() }
            }
            processingTask.expirationHandler = { workTask.cancel() }
        }
        #endif
    }

    #if os(iOS)
    /// Asks iOS for a background window to keep a library-preparation pass going.
    ///
    /// Opportunistic by design: the system decides when (typically charging and idle) and for how
    /// long, so this is not "always running in the background" — it is "resumes when allowed".
    static func scheduleLibraryPreparation() {
        let request = BGProcessingTaskRequest(identifier: "app.cassette.library.preparation")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(60)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif

    #if os(iOS)
    static func scheduleWrappedUpdate() {
        let request = BGProcessingTaskRequest(identifier: "app.cassette.wrapped.monthly-update")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(24 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        .onAppear { RuntimeDiagnostics.mark(.rootAppeared) }
                        .modifier(AccountVerificationLaunchPrompt())
                        .accessibilityIdentifier("cassette.content")
                        // .toastOverlay() must be the INNERMOST modifier: a toast pill now renders a
                        // CoverArtView, which reads @Environment(ArtworkImageCache.self) / appContainer.
                        // An overlay's content only inherits environments applied AFTER the overlay
                        // modifier (envs applied to the primary content below it do NOT reach the
                        // overlay's own view). So the env injections must sit below .toastOverlay().
                        .toastOverlay()
                        .environment(\.appContainer, container)
                        .environment(container.dominantColorExtractor)
                        .environment(container.artworkImageCache)
                        .modelContainer(container.modelContainer)
                        .environment(container.toastService)
                        .environment(chromeAppearance)
                } else if let bootFailureMessage {
                    StoreRecoveryView(
                        details: bootFailureMessage,
                        retry: {
                            self.bootFailureMessage = nil
                            bootAttempt += 1
                        },
                        reset: {
                            ModelContainer.resetAllCassetteStores()
                            self.bootFailureMessage = nil
                            bootAttempt += 1
                        }
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(CassetteColors.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color("LaunchBackground").ignoresSafeArea())
                }
            }
            .tint(CassetteColors.accent)
            .environment(\.locale, appLocale)
            .onAppear {
                #if os(macOS)
                NSApplication.shared.windows
                    .first { $0.title == "Mini Player" }?
                    .close()
                #endif
            }
            .task(id: bootAttempt) {
                #if DEBUG
                // Hosted unit tests construct isolated containers themselves. Starting the real
                // app here opens personal stores/network sessions and competes with audio tests.
                guard NSClassFromString("XCTestCase") == nil else { return }
                #endif
                guard container == nil else { return }
                // Let the boot ProgressView paint for one frame before heavy MainActor init.
                await Task.yield()

                LyricsTranslationSettings.registerDefaults()
                AppleMusicSettings.registerDefaults()
                AppBootGate.reset()
                Logger.boot.notice("🟡 AppContainer init start")
                let newContainer: AppContainer
                do {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--cassette-ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--cassette-reset-onboarding") {
                        UserDefaults.standard.set(false, forKey: "onboardingComplete")
                        UserDefaults.standard.set(false, forKey: "cassette.onboarding.pendingWelcome")
                    }
                    #endif
                    newContainer = try AppContainer(
                        inMemory: ProcessInfo.processInfo.arguments.contains("--cassette-ui-testing")
                    )
                } catch {
                    Logger.boot.error(
                        "AppContainer init failed; stores were preserved: \(error.localizedDescription, privacy: .public)"
                    )
                    bootFailureMessage = error.localizedDescription
                    return
                }

                // Publish immediately so RootView can replace the solid boot screen with its loader
                // while setup / persisted-server load continue.
                container = newContainer
                #if os(iOS)
                // Grants a background window that runs one preparation pass, so a long cover sync
                // can continue off-screen when iOS allows it.
                CassetteApp._bgLibraryPreparation = {
                    guard newContainer.serverState.activeServer != nil else {
                        if newContainer.serverState.isLoadingPersistedState {
                            CassetteApp.scheduleLibraryPreparation()
                        }
                        return
                    }
                    newContainer.libraryIndexService.ensureIndexed(using: newContainer.libraryService)
                    // Cover completion is independent of the server's track-count change check.
                    if BulkArtworkPreference.isEnabled,
                       !newContainer.albumCoverPreloadService.state.isComplete {
                        await newContainer.albumCoverPreloadService.downloadAllCovers(resumeDeferred: false)
                    }
                    guard !Task.isCancelled else { return }
                    await newContainer.libraryPreparationService.prepareIfLibraryChanged(
                        serverService: newContainer.serverService,
                        libraryService: newContainer.libraryService,
                        indexService: newContainer.libraryIndexService,
                        coverPreload: newContainer.albumCoverPreloadService
                    )
                }
                #endif
                Logger.boot.notice("🟡 container published (UI can leave solid launch screen)")

                Logger.boot.notice("🟡 setup() start")
                async let playerWiring: Void = newContainer.setup()
                newContainer.networkMonitor.start(serverState: newContainer.serverState) { [player = newContainer.playerService] path in
                    await player.handleNetworkPathChange(path)
                }
                newContainer.serverReachabilityMonitor.start()
                Logger.boot.notice("🟡 loadPersistedState() start")
                await newContainer.serverService.loadPersistedState()
                await newContainer.albumCoverPreloadService.restoreCompletedInventory()
                if let downloads = newContainer.downloadService as? DownloadService,
                   !ProcessInfo.processInfo.arguments.contains("--cassette-ui-testing") {
                    #if os(iOS)
                    CassetteBackgroundDownloads.shared.setRecoveryHandler { [weak downloads] in
                        await downloads?.recoverBackgroundDownloads()
                    }
                    #endif
                    Task(priority: .utility) { await downloads.recoverBackgroundDownloads() }
                }
                await playerWiring
                if #available(iOS 27.0, macOS 27.0, *) {
                    SiriBootGate.markReady()
                }
                Logger.boot.notice("🟡 loadPersistedState() done — activeServer = \(String(describing: newContainer.serverState.activeServer?.baseURL), privacy: .public)")

                // Warm Keychain + SwiftSonic client before Home's first shelf fetch.
                if newContainer.serverState.activeServer != nil {
                    await newContainer.serverService.preWarmClient()
                    await newContainer.nowPlayingBackgroundPreparation.prepare(using: newContainer)
                }

                // No Home tab yet (onboarding / no server) — don't hold deferred work for the full timeout.
                if newContainer.serverState.activeServer == nil {
                    AppBootGate.markHomeReady()
                }

                // Session restore waits for Home's first list so it doesn't compete for the Subsonic client.
                Task(priority: .utility) {
                    await AppBootGate.waitForHome()
                    Logger.boot.notice("🟡 restoreSession() start")
                    await newContainer.playerService.restoreSession()
                    Logger.boot.notice("🟡 restoreSession() done")
                }
                // Warm the Siri catalog (song store + Spotlight) once per server so the
                // first Siri request after install/login can resolve "this song" / artists
                // / playlists instead of failing with "couldn't get the data to process".
                Task(priority: .background) {
                    await AppBootGate.waitForHome()
                    guard newContainer.serverState.activeServer != nil else { return }
                    if #available(iOS 27.0, macOS 27.0, *) {
                        await newContainer.warmSiriLibrary()
                    }
                }
                Task(priority: .utility) {
                    AppContainer.invalidateCoverArtCacheIfNeeded(artworkCache: newContainer.artworkImageCache)
                    AppContainer.sweepLegacyCoverArtFiles()
                    await AppContainer.migrateAudioExtensionsIfNeeded(
                        modelContainer: newContainer.modelContainer,
                        cacheService: newContainer.cacheService
                    )
                    await AppContainer.migrateM4AFaststartIfNeeded(modelContainer: newContainer.modelContainer)
                    await runCoverArtGarbageCollection(container: newContainer)
                }
                Task(priority: .background) {
                    await AppBootGate.waitForHome()
                    guard newContainer.serverState.activeServer != nil else { return }
                    // Detect album-cover changes since the last launch and re-download any that moved.
                    _ = await newContainer.libraryIndexService.ensureIndexedAndWait(using: newContainer.libraryService)
                    // Upgrade old presentation facts even if the library count did not
                    // change. An offline launch can still repair existing local covers.
                    await newContainer.albumCoverPreloadService.prepareCachedThemes(
                        albumCovers: newContainer.libraryIndexService.albumArtworkSnapshot,
                        fillMissing: true)
                    newContainer.albumCoverPreloadService.reconcileChangedCovers()
                }
                Task(priority: .background) {
                    await AppBootGate.waitForHome()
                    await runWrappedUpdate(container: newContainer)
                    await newContainer.widgetSyncService.fullSync()
                }
                #if os(iOS)
                CassetteApp._bgTaskService = newContainer.wrappedPlaylistService
                CassetteApp._bgTaskServerState = newContainer.serverState
                CassetteApp.scheduleWrappedUpdate()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .cassetteServerCredentialsChanged)) { _ in
                guard let c = container else { return }
                Task { await c.invalidateAPIClientsAfterCredentialChange() }
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                // Tell the budget first: it stops heavy artwork analysis and beat visuals while the
                // caches below are being trimmed.
                PerformanceGovernor.shared.handleMemoryPressure()
                guard let c = container else { return }
                c.artworkImageCache.clearCache()
                Task {
                    await c.libraryService.trimDetailCaches()
                    await c.externalArtworkCache.clearMemoryCache()
                    await c.nowPlayingService.clearArtworkCache()
                }
            }
            #endif
            .task(id: container?.serverState.isOnline) {
                guard let c = container, c.serverState.isOnline else { return }
                await c.playerService.handleNetworkRestored()
                await c.listenBrainzService.flushOfflineQueue()
            }
            // Same recovery, for the case `isOnline` never changes: the device kept its route but the
            // *server* went away and came back (restart, VPN re-dial, DNS flapping).
            .task(id: container?.serverState.isServerReachable) {
                guard let c = container, c.serverState.isServerReachable else { return }
                await c.playerService.handleNetworkRestored()
                await c.listenBrainzService.flushOfflineQueue()
            }
            #if os(macOS)
            .frame(minHeight: 580)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                guard let c = container else { return }
                // Stop AVAudioEngine synchronously — prevents HALC frame accumulation during teardown.
                c.playerService.stopAudioEngineSync()
                let sema = DispatchSemaphore(value: 0)
                Task {
                    await c.playerService.stop()
                    await c.nowPlayingService.stop()
                    sema.signal()
                }
                let result = sema.wait(timeout: .now() + 1.5)
                #if DEBUG
                if result == .timedOut {
                    Logger.boot.warning("[APP] Terminate handler timed out after 1.5s")
                }
                #endif
            }
            #endif
        }
        .onChange(of: container?.artworkImageCache.allowsNetworkDownloads) { _, allowed in
            guard let c = container else { return }
            if allowed != true { c.albumCoverPreloadService.pauseAutomaticDownloads() }
            else { c.albumCoverPreloadService.resumeArtworkAfterNetworkChange() }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            let playing = container?.playerState.playbackState == .playing
            let intent = container?.playerState.playbackState.hasPlaybackIntent ?? false
            let position = container?.playerState.position ?? 0
            Logger.boot.notice("[SCENE] run=\(RuntimeDiagnostics.sessionID, privacy: .public) phase=\(String(describing: oldPhase), privacy: .public)->\(String(describing: newPhase), privacy: .public) playing=\(playing, privacy: .public) playback_intent=\(intent, privacy: .public) position_s=\(position, format: .fixed(precision: 2), privacy: .public)")
            // Foreground/background drives most of the budget (animated chrome, beat visuals,
            // prefetch). Only `.background` counts as "not active": on macOS a momentarily
            // unfocused window (or a focused mini player next to a hidden main window) must not
            // stop the other window's motion, and on iOS the per-view `scenePhase == .active`
            // checks still pause during a Control Center peek.
            PerformanceGovernor.shared.setAppActive(newPhase != .background)
            guard let c = container else { return }
            // The reachability poll is pointless while suspended, and a resume should re-ping before
            // the server-backed tabs redraw rather than show a stale "unreachable" state.
            c.serverReachabilityMonitor.isAppActive = newPhase != .background
            switch newPhase {
            case .active:
                Task(priority: .utility) {
                    await (c.downloadService as? DownloadService)?.recoverBackgroundDownloads()
                }
                if c.serverState.activeServer != nil, !c.albumCoverPreloadService.state.isComplete {
                    c.albumCoverPreloadService.reconcileChangedCovers()
                }
                Task(priority: .utility) {
                    await c.serverReachabilityMonitor.checkNow()
                }
                // Recover audio first (screenshot / app-switch crackle), then reload settings.
                Task(priority: .userInitiated) {
                    await c.playerService.handleAppBecameActive()
                    // CR-01: re-enable skip/previous after sleep so CarPlay / lock screen respond.
                    await c.nowPlayingService.reassertRemoteCommands()
                }
                Task(priority: .utility) {
                    let previousRG = c.replayGainSettings.config
                    let previousCF = c.crossfadeSettings.config
                    let previousGapless = c.gaplessSettings.config
                    let previousMaxBytes = c.cacheSettings.maxCacheBytes
                    c.streamingSettings.reloadFromDefaults()
                    c.cacheSettings.reloadFromDefaults()
                    c.replayGainSettings.reloadFromDefaults()
                    c.crossfadeSettings.reloadFromDefaults()
                    c.gaplessSettings.reloadFromDefaults()
                    LyricsTranslationSettings.shared.reloadFromDefaults()
                    AppleMusicSettings.shared.reloadFromDefaults()
                    #if os(iOS)
                    MusicHapticsController.shared.refresh()
                    #endif
                    ShareSettings.shared.reloadFromDefaults()
                    if c.cacheSettings.maxCacheBytes != previousMaxBytes {
                        await c.cacheService.setMaxBytes(c.cacheSettings.maxCacheBytes)
                    }
                    if c.replayGainSettings.config != previousRG {
                        await c.playerService.replayGainSettingsDidChange()
                    }
                    if c.crossfadeSettings.config != previousCF {
                        await c.playerService.crossfadeSettingsDidChange()
                    }
                    if c.gaplessSettings.config != previousGapless {
                        await c.playerService.gaplessSettingsDidChange()
                    }
                }
            case .inactive:
                // Control Center / switcher peek — do not schedule engine health-checks.
                Task(priority: .utility) {
                    await c.playerService.handleAppWillResignActive()
                }
            case .background:
                // Position-only, off the hot path. Encoding the full queue here used to hitch
                // audio whenever the user switched apps (SwiftData + JSON on the main actor).
                Task(priority: .utility) {
                    await c.playerService.handleAppDidEnterBackground()
                    await c.playerService.saveCurrentPosition()
                }
                Logger.session.debug("App backgrounded — position checkpoint")
            default:
                break
            }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commands {
            CassetteCommands()
        }
        #endif

        #if os(macOS)
        CassetteSettingsScene(container: container)

        Window("Mini Player", id: "mini-player") {
            Group {
                if let container {
                    MiniPlayerWindowView()
                        .environment(\.appContainer, container)
                        .environment(container.dominantColorExtractor)
                        .environment(container.artworkImageCache)
                        .modelContainer(container.modelContainer)
                } else {
                    MiniPlayerWindowView()
                }
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 136)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)
        #endif
    }

    private var appLocale: Locale {
        _ = appLanguageCode
        return AppUILanguage.locale
    }

    // MARK: - Cover art garbage collection

    @MainActor
    private func runCoverArtGarbageCollection(container: AppContainer) async {
        let context = container.modelContainer.mainContext
        var referencedIds: Set<String> = []

        let albums = (try? context.fetch(FetchDescriptor<DownloadedAlbum>())) ?? []
        for album in albums {
            if let id = album.coverArtId { referencedIds.insert(id) }
        }

        let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>())) ?? []
        for track in tracks {
            if let id = track.coverArtId { referencedIds.insert(id) }
        }

        let playlists = (try? context.fetch(FetchDescriptor<DownloadedPlaylist>())) ?? []
        for playlist in playlists {
            if let id = playlist.coverArtId { referencedIds.insert(id) }
        }

        let pinned = (try? context.fetch(FetchDescriptor<PinnedItem>())) ?? []
        for item in pinned {
            if let id = item.coverArtId { referencedIds.insert(id) }
        }

        await container.downloadService.garbageCollectOrphanedCovers(referencedIds: referencedIds)
    }

    // MARK: - Wrapped update

    @MainActor
    private func runWrappedUpdate(container: AppContainer) async {
        guard let serverId = container.serverState.activeServer?.id.uuidString else { return }
        await container.wrappedPlaylistService.handleYearTransitionIfNeeded(serverId: serverId, calendar: .current)
        let result = await container.wrappedPlaylistService.runYearlyPlaylistSyncIfNeeded(serverId: serverId, calendar: .current)
        Logger.wrapped.info("Cold start result: \(String(describing: result), privacy: .public)")
    }
}

private struct StoreRecoveryView: View {
    let details: String
    let retry: () -> Void
    let reset: () -> Void

    @State private var isShowingResetConfirmation = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(CassetteColors.accent)

            Text("Cassette couldn’t open its local library")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Your data has not been deleted. Check available disk space, then try again. Reset only if the problem continues after you have made a backup.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Text(details)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)

                Button("Reset Local Database", role: .destructive) {
                    isShowingResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("LaunchBackground").ignoresSafeArea())
        .accessibilityIdentifier("cassette.storage-recovery")
        .alert("Reset local database?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("This permanently deletes Cassette’s local index, favorites, listening history, and download records. Server credentials stored in Keychain are not deleted.")
        }
    }
}
