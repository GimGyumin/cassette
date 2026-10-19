import Foundation
import AudioStreaming
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@MainActor
final class AuditResolver: MediaResolverProtocol {
    var resolveCount = 0
    var operation: (() async throws -> MediaSource)?
    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        resolveCount += 1
        guard let operation else { throw URLError(.notConnectedToInternet) }
        return try await operation()
    }
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource { throw URLError(.unsupportedURL) }
}

@MainActor
final class AuditPlaybackFixture {
    let engine = FakePlaybackEngine()
    let container: AppContainer
    let resolver = AuditResolver()
    let library = SearchLibraryStub()
    let player: PlayerService
    let track = DisplayableSong(id: "audit-track", title: "Audit", duration: 180)
    init() throws {
        container = try AppContainer(inMemory: true, engine: engine)
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Audit", baseURL: "https://example.invalid", username: "audit"))
        player = PlayerService(state: container.playerState, mediaResolver: resolver,
            serverService: container.serverService, sessionService: container.sessionService,
            artworkImageCache: container.artworkImageCache, lyricsService: container.lyricsService,
            libraryService: library, cacheService: container.cacheService,
            downloadService: container.downloadService, cacheSettings: container.cacheSettings,
            streamingSettings: container.streamingSettings, replayGainSettings: container.replayGainSettings,
            crossfadeSettings: container.crossfadeSettings, gaplessSettings: container.gaplessSettings,
            toastService: container.toastService, statsService: container.statsService,
            listenBrainzService: container.listenBrainzService, engine: engine)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.duration = 180
        container.playerState.position = 60
        container.playerState.playbackState = .playing
        engine.progress = 60
        engine.state = .playing
    }
}

@MainActor
@Suite("Audit playback hardening", .serialized)
struct AuditPlaybackHardeningTests {
    @Test(arguments: [PlaybackState.loading, .playing, .buffering, .recovering])
    func zeroClockStartupTimesOutWithoutSkippingTrack(phase: PlaybackState) async throws {
        let f = try AuditPlaybackFixture()
        await f.player.installAuditRemoteSource()
        await f.player.armUnresolvedSelection()
        f.engine.progress = 0
        f.container.playerState.position = 0
        f.container.playerState.playbackState = phase
        let context = await f.player.playbackContext
        let watchdog = await f.player.makePlaybackStartWatchdog(context: context, songID: f.track.id,
                                                                timeout: .milliseconds(20))
        await watchdog.value
        #expect(f.container.playerState.playbackState == .error(.timeout))
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(f.container.playerState.queue.map(\.id) == [f.track.id])
        #expect(f.engine.calls.contains(.stop))
        await f.player.stop()
    }

    @Test func startupDeadlinePreservesProgressAndUserPause() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.installAuditRemoteSource()
        await f.player.armUnresolvedSelection()
        f.engine.progress = 1
        let context = await f.player.playbackContext
        let playing = await f.player.makePlaybackStartWatchdog(context: context, songID: f.track.id,
                                                              timeout: .milliseconds(20))
        await playing.value
        #expect(f.container.playerState.playbackState == .playing)
        f.engine.progress = 0
        f.container.playerState.playbackState = .paused
        let paused = await f.player.makePlaybackStartWatchdog(context: context, songID: f.track.id,
                                                             timeout: .milliseconds(20))
        await paused.value
        #expect(f.container.playerState.playbackState == .paused)
        // A newer transport command makes the old deadline inert, even on the same song.
        await f.player.beginSystemInterruption()
        f.container.playerState.playbackState = .loading
        let obsolete = await f.player.makePlaybackStartWatchdog(context: context, songID: f.track.id,
                                                               timeout: .milliseconds(20))
        await obsolete.value
        #expect(f.container.playerState.playbackState == .loading)
        await f.player.stop()
    }

    @Test func unsuccessfulQueuedHandoffReusesResolvedNextSource() async throws {
        let f = try AuditPlaybackFixture()
        let next = DisplayableSong(id: "prepared-next", title: "Prepared", duration: 180)
        f.container.playerState.queue = [f.track, next]
        f.container.playerState.currentIndex = 0
        f.container.playerState.position = 180
        f.engine.progress = 180
        let source = MediaSource.stream(URL(string: "https://example.invalid/prepared.flac")!, customHeaders: [:])
        await f.player.armAuditPreparedNext(next, source: source)
        // The fake engine never selects its queue entry, exercising the grace-window fallback.
        await f.player.handleEndOfTrack(engineConfirmed: true)
        #expect(f.resolver.resolveCount == 0)
        #expect(f.container.playerState.currentTrack?.id == next.id)
        #expect(f.container.playerState.currentIndex == 1)
        await f.player.stop()
    }

    @Test func failedCachedSourceIsReplacedOnceAndDoesNotSkipSelection() async throws {
        let f = try AuditPlaybackFixture()
        let remote = MediaSource.stream(URL(string: "https://example.invalid/recovered.flac")!, customHeaders: [:])
        f.resolver.operation = { remote }
        await f.player.armAuditFailedCache()
        f.engine.progress = 0
        f.container.playerState.position = 0
        let context = await f.player.playbackContext
        #expect(await f.player.recoverFailedCachedPlayback(context: context))
        #expect(f.resolver.resolveCount == 1)
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(f.container.playerState.queue.map(\.id) == [f.track.id])
        #expect(!(await f.player.recoverFailedCachedPlayback(context: context)))
        #expect(f.resolver.resolveCount == 1)
        await f.player.stop()
    }

    @Test func truncatedCachedEOFRecoversTheSameTrackInsteadOfAdvancing() async throws {
        let f = try AuditPlaybackFixture()
        f.resolver.operation = { .stream(URL(string: "https://example.invalid/original.flac")!, customHeaders: [:]) }
        await f.player.armAuditFailedCache()
        f.engine.progress = 12
        f.container.playerState.position = 12
        await f.player.handleEndOfTrack(engineConfirmed: true, finishedProgress: 12)
        #expect(f.resolver.resolveCount == 1)
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(f.container.playerState.currentIndex == 0)
        #expect(f.container.playerState.position >= 12)
        await f.player.stop()
    }

    @Test func cachedEOFUsesParsedDurationWhenCatalogDurationIsWrong() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.armAuditFailedCache()
        f.engine.progress = 12
        f.engine.duration = 12
        f.container.playerState.position = 12
        f.container.playerState.repeatMode = .off
        f.container.playerState.isAutoExtendEnabled = false
        await f.player.handleEndOfTrack(engineConfirmed: true, finishedProgress: 12)
        #expect(f.resolver.resolveCount == 0)
        #expect(f.container.playerState.playbackState == .paused)
        await f.player.stop()
    }

    @Test func cancelledCallerWithLateSuccessfulResolverSettlesPendingSelection() async throws {
        let f = try AuditPlaybackFixture()
        let held = HeldAuditResult<MediaSource>()
        f.resolver.operation = { await held.value() }
        let request = Task { try await f.player.play(tracks: [f.track], startIndex: 0) }
        var started = held.starts.makeAsyncIterator()
        _ = await started.next()
        #expect(f.container.playerState.playbackState == .loading)
        request.cancel()
        held.finish(.stream(URL(string: "https://example.invalid/cancelled.flac")!, customHeaders: [:]))
        try await request.value
        #expect(f.container.playerState.playbackState == .paused)
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(!(await f.player.isTrackTransitionPending))
        await f.player.stop()
    }

    @Test func unresolvedSelectionTimesOutAndPreservesQueue() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.armUnresolvedSelection()
        f.container.playerState.playbackState = .loading
        let context = await f.player.playbackContext
        let request = await f.player.playbackRequestID
        let watchdog = await f.player.makePlaybackResolutionWatchdog(context: context, requestID: request, timeout: .milliseconds(30))
        await watchdog.value
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(f.container.playerState.queue.map(\.id) == [f.track.id])
        #expect(f.container.playerState.playbackState == .error(.timeout))
        #expect(!(await f.player.isTrackTransitionPending))
        await f.player.stop()
    }

    @Test func rejectedEarlySeekDoesNotInvalidatePendingPlay() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.armUnresolvedSelection()
        f.container.playerState.playbackState = .loading
        let context = await f.player.playbackContext
        await f.player.seek(to: 120)
        #expect(await f.player.playbackContext == context)
        #expect(f.container.playerState.pendingSeekPosition == nil)
        await f.player.stop()
    }

    @Test func resolutionWatchdogCannotOverwritePauseOrNewRequest() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.armUnresolvedSelection()
        let context = await f.player.playbackContext
        let request = await f.player.playbackRequestID
        let watchdog = await f.player.makePlaybackResolutionWatchdog(context: context, requestID: request, timeout: .milliseconds(50))
        await f.player.pause()
        await watchdog.value
        #expect(f.container.playerState.playbackState == .paused)
        await f.player.stop()
    }

    @Test func failedStallRefreshTerminatesAndRetainsPosition() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.installAuditRemoteSource()
        await f.player.recoverFromStalledStream()
        #expect(f.resolver.resolveCount == 1)
        if case .error = f.container.playerState.playbackState {} else { Issue.record("failed refresh must terminate") }
        #expect(f.container.playerState.position == 60)
        #expect(await f.player.progressTask == nil)
        await f.player.stop()
    }

    @Test func disabledAutoplayNeverFetchesOrChangesPreference() async throws {
        let f = try AuditPlaybackFixture()
        var fetches = 0
        f.library.backfillOperation = { fetches += 1; return [] }
        f.container.playerState.isAutoExtendEnabled = false
        try await f.player.skipToNext()
        #expect(fetches == 0)
        #expect(!f.container.playerState.isAutoExtendEnabled)
        #expect(f.container.playerState.playbackState == .paused)
        await f.player.stop()
    }

    @Test func duplicateSongAtAnotherQueueIndexIsASelection() async throws {
        let f = try AuditPlaybackFixture()
        f.container.playerState.queue = [f.track, f.track]
        await f.player.armAuditProgressTask()
        await #expect(throws: URLError.self) {
            try await f.player.play(tracks: [f.track, f.track], startIndex: 1)
        }
        #expect(f.container.playerState.currentIndex == 1)
        #expect(f.resolver.resolveCount > 0)
        await f.player.stop()
    }

    @Test func stalledLocalRecoveryAcceptsAnEstablishedClockButNotPausedIntent() {
        #expect(PlayerService.shouldRecoverFromLocalMedia(phase: .stalled, trackMatches: true,
            playbackState: .buffering, engineProgress: 60, sourceIsLocal: false, transitionPending: false))
        #expect(!PlayerService.shouldRecoverFromLocalMedia(phase: .acquiring, trackMatches: true,
            playbackState: .buffering, engineProgress: 60, sourceIsLocal: false, transitionPending: false))
        for phase in [PlaybackState.paused, .idle, .error(.timeout)] {
            #expect(!PlayerService.shouldRecoverFromLocalMedia(phase: .stalled, trackMatches: true,
                playbackState: phase, engineProgress: 60, sourceIsLocal: false, transitionPending: false))
        }
    }

    @Test func terminalFailureClosesTheListeningSegmentAndRejectsLateConfirmation() async throws {
        let f = try AuditPlaybackFixture()
        await f.player.armAuditSegmentAndTasks()
        let context = await f.player.playbackContext
        await f.player.finishPlaybackFailure(.timeout, context: context, position: 60)
        let seconds = await f.player.accumulatedPlayedSeconds
        #expect(seconds >= 10 && seconds < 11)
        #expect(await f.player.currentPlaySegmentStart == nil)
        #expect(await f.player.progressTask == nil)
        #expect(await f.player.playbackAcquisitionTask == nil)
        #expect(await f.player.cacheDownloadTask == nil)
        await f.player.finishPlaybackFailure(.timeout, context: context, position: 0)
        await f.player.publishEnginePlaybackConfirmation()
        #expect(await f.player.accumulatedPlayedSeconds == seconds)
        #expect(f.container.playerState.position == 60)
        if case .error = f.container.playerState.playbackState {} else { Issue.record("terminal error was overwritten") }
        await f.player.stop()
    }

    @Test func oldPresentationCannotCommitAfterPause() async throws {
        let f = try AuditPlaybackFixture()
        let context = await f.player.playbackContext
        await f.player.pause()
        let committed = await f.player.commitPresentation(context) { state in
            state.playbackState = .playing
            return true
        }
        #expect(!committed)
        #expect(f.container.playerState.playbackState == .paused)
        await f.player.stop()
    }

    @Test func interruptionInvalidatesAResolverThatIgnoresCancellation() async throws {
        let f = try AuditPlaybackFixture()
        let held = HeldAuditResult<MediaSource>()
        f.resolver.operation = { await held.value() }
        var starts = held.starts.makeAsyncIterator()
        let pending = Task { try await f.player.play(tracks: [f.track], startIndex: 0) }
        _ = await starts.next()
        await f.player.beginSystemInterruption()
        held.finish(.downloaded(URL(fileURLWithPath: "/tmp/late-interruption.mp3")))
        try await pending.value
        #expect(!f.player.systemEngine.hasCurrentItem)
        #expect(!f.engine.calls.contains { if case .play = $0 { return true }; return false })
        #expect(await f.player.transport.interrupted)
        await f.player.stop()
    }

    @Test func lateSmartShuffleDoesNotUndoStop() async throws {
        let f = try AuditPlaybackFixture()
        let held = HeldAuditResult<[DisplayableSong]>()
        f.library.smartShuffleOperation = { await held.value() }
        var starts = held.starts.makeAsyncIterator()
        let pending = Task { try await f.player.playSmartShuffle() }
        _ = await starts.next()
        await f.player.stop()
        held.finish([f.track])
        try await pending.value
        #expect(f.resolver.resolveCount == 0)
        #expect(f.container.playerState.playbackState == .idle)
        #expect(!f.container.playerState.isSmartShuffleActive)
    }

    @Test func migrationReadFailureDoesNotMarkCompletion() throws {
        let source = try ModelContainer.cassette(inMemory: true)
        let target = try ModelContainer.listening(inMemory: true)
        let suite = "audit-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppContainer.migratePlaybackEventsIfNeeded(from: source, to: target, defaults: defaults,
            fetch: { _ in throw CocoaError(.fileReadNoPermission) })
        #expect(!defaults.bool(forKey: "cassette.listeningEventsMigrated.v1"))
        AppContainer.migratePlaybackEventsIfNeeded(from: source, to: target, defaults: defaults)
        #expect(defaults.bool(forKey: "cassette.listeningEventsMigrated.v1"))
    }

    @Test func originalLossyCodecDoesNotBecomeTranscoded() async throws {
        let f = try AuditPlaybackFixture()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SilentMP3.mp3")
        await f.player.installAuditNativeSource(url)
        let id = try #require(f.player.systemEngine.observedItemID)
        let generation = await f.player.systemPlayback.generation
        await f.player.handleSystemEngineEvent(.codec(generation, id, "MP3"))
        #expect(!f.container.playerState.isDeliveringTranscodedAudio)
        await f.player.stop()
    }

    @Test func rapidWidgetChangesPersistTheFinalValue() async throws {
        let f = try AuditPlaybackFixture()
        let suite = "audit-widget-\(UUID())"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let widget = WidgetSyncService(dominantColorExtractor: f.container.dominantColorExtractor,
            modelContainer: f.container.modelContainer, artworkCache: f.container.artworkImageCache,
            coversDirectory: FileManager.default.temporaryDirectory,
            serverState: f.container.serverState, storage: storage)
        await widget.onPlayStateChanged(isPlaying: false, currentSong: f.track)
        await widget.onPlayStateChanged(isPlaying: true, currentSong: f.track)
        let data = try #require(storage.data(forKey: SharedStorageKey.nowPlayingState.rawValue))
        let value = try JSONDecoder().decode(SharedNowPlayingState.self, from: data)
        #expect(value.isPlaying)
    }
}

extension PlayerService {
    func installAuditNativeSource(_ url: URL) {
        currentSource = .downloaded(url)
        systemPlayback.isActive = true
        systemEngine.start(url: url, headers: [:], generation: systemPlayback.generation,
                           position: 0, paused: true, reusingPlayer: false)
    }
    func installAuditRemoteSource() {
        currentSource = .stream(URL(string: "https://example.invalid/audit.flac")!, customHeaders: [:])
    }
    func armAuditProgressTask() {
        progressTask = Task { try? await Task.sleep(for: .seconds(60)) }
    }
}

@MainActor
final class HeldAuditResult<Value: Sendable> {
    nonisolated let starts: AsyncStream<Void>
    private let events: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Value, Never>?
    init() { (starts, events) = AsyncStream.makeStream() }
    func value() async -> Value {
        await withCheckedContinuation { pending = $0; events.yield(()) }
    }
    func finish(_ value: Value) { pending?.resume(returning: value); pending = nil }
}

extension PlayerService {
    func armAuditSegmentAndTasks() {
        currentPlaySegmentStart = Date().addingTimeInterval(-10)
        progressTask = Task { try? await Task.sleep(for: .seconds(60)) }
        playbackAcquisitionTask = Task { try? await Task.sleep(for: .seconds(60)) }
        cacheDownloadTask = Task { try? await Task.sleep(for: .seconds(60)) }
    }
}

extension PlayerService {
    func armUnresolvedSelection() { isTrackTransitionPending = true; transport.intent = .play }
}

extension PlayerService {
    func armAuditPreparedNext(_ next: DisplayableSong, source: MediaSource) {
        transport.intent = .play
        currentSource = .stream(URL(string: "https://example.invalid/current.flac")!, customHeaders: [:])
        gaplessBridge.arm(next: next, source: source, epoch: playbackEpoch)
    }
}

extension PlayerService {
    func armAuditFailedCache() {
        transport.intent = .play
        currentSource = .cached(URL(fileURLWithPath: "/tmp/cassette-failed-cache.m4a"))
    }
}
