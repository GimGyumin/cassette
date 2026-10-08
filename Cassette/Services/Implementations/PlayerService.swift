// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

nonisolated enum CrossfadePhase: Sendable {
    case fadeOut
    case fadeIn
}

/// State for an AudioStreaming entry that is already queued inside the engine.
/// Kept together so queue resets and engine handovers cannot leave a stale bridge flag.
nonisolated struct GaplessBridgeState: Sendable {
    var next: DisplayableSong?
    var source: MediaSource?
    var epoch: UInt64 = 0
    var wasSelected = false
    var recoveryWasRequested = false

    mutating func arm(next: DisplayableSong, source: MediaSource, epoch: UInt64) {
        self.next = next
        self.source = source
        self.epoch = epoch
        wasSelected = false
        recoveryWasRequested = false
    }

    mutating func reset() {
        next = nil
        source = nil
        epoch = 0
        wasSelected = false
        recoveryWasRequested = false
    }

    mutating func clearPreparedSource() {
        next = nil
        source = nil
    }
}

/// AVPlayer handover and stall-recovery state. The generation fences late engine
/// callbacks after a teardown; recovery and seek windows belong to that same engine.
nonisolated struct SystemPlaybackState: Sendable {
    var isActive = false
    var generation: UInt64 = 0
    var transitionRequestedAt: Date?
    var lastWaitingLogAt = Date.distantPast
    var recoveredCurrentStall = false
    var seekSettleDeadline = Date.distantPast
    var lastStallRecoveryAt = Date.distantPast

    mutating func invalidateCallbacks() { generation &+= 1 }
    mutating func resetTrackRecovery() { recoveredCurrentStall = false }
}

actor PlayerService: PlayerServiceProtocol {
    nonisolated let state: PlayerState

    let mediaResolver: any MediaResolverProtocol
    let serverService: any ServerServiceProtocol
    let sessionService: PlaybackSessionService
    let artworkImageCache: ArtworkImageCache
    let lyricsService: LyricsService
    let libraryService: any LibraryServiceProtocol
    let cacheService: any CacheServiceProtocol
    let downloadService: any DownloadServiceProtocol
    let cacheSettings: CacheSettings
    let streamingSettings: StreamingSettings
    let replayGainSettings: ReplayGainSettings
    let crossfadeSettings: CrossfadeSettings
    var crossfadeConfig = CrossfadeConfig(duration: 0, disableForGapless: true)
    let gaplessSettings: GaplessSettings
    /// Snapshot of the gapless preference; refreshed by `gaplessSettingsDidChange()`.
    var gaplessEnabled = GaplessSettings.defaultEnabled
    var nowPlayingService: (any NowPlayingServiceProtocol)?
    var widgetSyncService: WidgetSyncService?
    var replayGainService: ReplayGainService?
    let toastService: ToastService
    let statsService: StatsService
    let listenBrainzService: ListenBrainzService
    let jellyfinService: JellyfinService?

    /// The audio engine, behind `PlaybackEngine` so queue/transition logic is testable with a fake
    /// and a future adaptive-buffer path can swap the engine. Single instance for the app lifetime.
    let engine: any PlaybackEngine
    /// The engine's AVFoundation graph (ReplayGain EQ node, beat tap). Nil for engines without one.
    private let audioGraph: (any AudioGraphHosting)?
    private let audioDelegate: AudioStreamingDelegate
    var progressTask: Task<Void, Never>?
    var playbackRequestTask: Task<Void, Error>?
    /// Bounded recovery for a finite track whose engine never advances beyond initial loading.
    /// Cancelled whenever the user changes transport state or selects another track.
    var playbackAcquisitionTask: Task<Void, Never>?
    var playbackRequestID: UInt64 = 0
    var gaplessPreparationTask: Task<Void, Never>?
    var gaplessPreparationGeneration: UInt64 = 0
    var nextGaplessPreparationAttempt = Date.distantPast
    /// Pending seek + optional pause applied once the player first reaches `.playing`.
    var pendingRestoreInfo: (seekTime: Double, pause: Bool)?
    /// While a user seek is settling, hold the scrubber at the requested target until the
    /// engine reports that it actually landed. Remote streams can take longer than a fixed
    /// delay, especially when seeking backward outside the current buffer.
    var seekState: PlaybackSeekState = .idle
    /// Gapless bridge: when the AudioPlayer's internal queue already holds the next
    /// pre-buffered entry, a natural EOF transitions seamlessly. Cassette must then advance app
    /// state to that already-playing track instead of re-calling `play()` (which would flush the
    /// engine and re-create the gap). Whether an entry may be armed at all is decided by
    /// `GaplessPolicy` (user setting, crossfade arbitration, metered network, device budget).
    var gaplessBridge = GaplessBridgeState()
    /// Set when next-track artwork preload was skipped because the app was backgrounded;
    /// cleared (and retried) when the app becomes active again.
    var needsArtworkPreloadRecheck = false
    /// Source of the currently playing track; kept for repeat-one replay.
    var currentSource: MediaSource?
    /// A server-offset response starts its engine clock at zero. App/UI clocks remain song-relative.
    var streamTimeOffset: TimeInterval = 0
    var liveStreamStallTask: Task<Void, Never>?

    /// AVPlayer path for Dolby Atmos / E-AC-3 / multichannel so Spatial Audio can engage.
    nonisolated let systemEngine = AVPlayerPlaybackEngine()
    var systemPlayback = SystemPlaybackState()

    var audioSessionConfigured = false
    #if os(iOS)
    var interruptionObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var spatialCapabilitiesObserver: NSObjectProtocol?
    /// Stored so pause()/stop() can cancel it before calling setActive(false).
    var sessionActivationRetryTask: Task<Void, Never>?
    /// True when the current interruption began because the output route was disconnected.
    var interruptionWasRouteDisconnect = false
    /// We were playing when an interruption began — resume only when the system says `.shouldResume`
    /// (phone call / Siri), or via the screenshot-specific deferred path. Never keep the engine
    /// writing into a deactivated session (that wedges system audio).
    var interruptedWhilePlaying = false
    /// Only a screenshot correlated with an active interruption may request recovery on `.ended`.
    var pendingScreenshotResume = false
    var audioInterruptionActive = false
    /// When the screenshot notification was last seen — soft-interrupt window for `.began`.
    var screenshotNotedAt: Date?
    /// Brief delay before hard-pausing on interruption so a screenshot note can cancel it.
    var deferredInterruptionPauseTask: Task<Void, Never>?
    /// True once `applyHardInterruptionPause` ran for the current interruption cycle.
    var hardPausedForCurrentInterruption = false
    /// True when we left the foreground while AudioStreaming was supposed to be playing.
    /// Used for a cheap progress health-check on return (not an automatic rebuild).
    var mayNeedPlaybackHealthCheck = false
    /// Scrubber position snapshot taken on background — engine progress can reset to ~0 after suspend.
    var lastForegroundProgress: TimeInterval = 0
    /// Song id for `lastForegroundProgress` — must not span auto-skip to the next track in background.
    var lastForegroundProgressSongId: String?
    /// Prevents stacked rebuilds (rapid app switching) from freezing the player actor.
    var isRebuildingEngine = false
    var lastEngineRebuildAt: Date = .distantPast
    var screenshotObserver: NSObjectProtocol?
    #endif

    var isHandlingEndOfTrack = false
    /// Debounces an engine EOF and the progress watchdog observing the same transition.
    /// Without this, a late duplicate callback can be interpreted as the next track ending.
    var lastEndOfTrackTransitionAt: Date = .distantPast
    /// Detects AudioStreaming's progress wrapping to zero when its pre-queued item starts.
    var lastObservedEngineProgress: TimeInterval = 0
    /// Progress near end of track — used when AudioStreaming EOF never fires (common on AirPlay).
    var endOfTrackStallStartedAt: Date?
    var endOfTrackStallProgress: Double = -1
    /// True when playback stopped cleanly at the END of the queue (repeat off).
    var stoppedAtEndOfQueue = false
    /// True during the URL-resolution phase of session restore.
    var isRestoringSession = false
    /// Stored handle for the 150 ms deferred-pause task during session restore.
    var restorePauseTask: Task<Void, Never>?
    /// True while the player is muted for the restore seek window (150 ms).
    var isMutedForRestore = false
    /// Last saved volume from UserDefaults, defaulting to 0.7.
    nonisolated var restoredVolume: Float {
        #if os(iOS)
        // iOS exposes device/route volume through MPVolumeView. Keep the software player at
        // unity gain or every route is capped a second time (the UI slider appeared unable to
        // reach full volume, and AudioStreaming/AVPlayer did not have matching loudness).
        return 1.0
        #else
        guard UserDefaults.standard.object(forKey: "cassette.lastVolume") != nil else { return 0.7 }
        return Float(UserDefaults.standard.double(forKey: "cassette.lastVolume"))
        #endif
    }
    var positionSaveTask: Task<Void, Never>?
    /// Task reserved for the playing-now notification. Cancelled on track change.
    var playingNowTask: Task<Void, Never>?
    var detector = ScrobbleThresholdDetector()
    /// Re-stamps Now Playing ISRC so system Music Haptics can finish loading without XPC probes.
    var musicHapticsNudgeTask: Task<Void, Never>?
    /// Warms catalog ISRC cache for the next queued track.
    var nextTrackISRCPrefetchTask: Task<Void, Never>?
    /// Task scheduled to download and cache the current track at +30s of playback.
    var cacheDownloadTask: Task<Void, Never>?
    /// Ordered history writes survive track changes; audio never waits for their persistence.
    var historyWriteTask: Task<Void, Never>?
    var periodicPlaybackReportTask: Task<Void, Never>?
    var gaplessMetadataTask: Task<Void, Never>?
    let cacheSession: URLSession
    /// Task that prefetches the next queued track into cache ahead of the crossfade window.
    var prefetchTask: Task<Void, Never>?
    var prefetchScheduled = false
    let prefetchSession: URLSession
    /// Fade-out task running during the crossfade window at the end of the current track.
    var fadeOutTask: Task<Void, Never>?
    /// Fade-in task running at the start of the next track after a crossfade.
    var fadeInTask: Task<Void, Never>?
    /// True while a crossfade fade-out is in progress.
    var isFadingOut = false
    // Saved before a shuffle activation; nil when shuffle is off.
    var originalQueueOrder: [DisplayableSong]?
    /// Single-slot guard preventing concurrent auto-extend fetches.
    var autoExtendFetchTask: Task<Void, Never>?
    nonisolated static let autoExtendUserDefaultsKey = "cassette.player.autoExtendEnabled"
    nonisolated static let automaticDownloadUserDefaultsKey = "cassette.download.automaticAfterStreaming"
    nonisolated static let automaticDownloadOverCellularUserDefaultsKey = "cassette.download.automaticOverCellular"
    private nonisolated static let listeningHistoryUserDefaultsKey = "cassette.history.enabled"
    nonisolated static var isListeningHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: listeningHistoryUserDefaultsKey) as? Bool ?? true
    }
    var automaticDownloadCheckDate = Date.distantPast
    var automaticDownloadTasks: Set<String> = []

    /// Wall-clock time when the current track first started.
    var trackPlayStartDate: Date?
    /// Seconds of actual (non-paused) playback accumulated for the current track.
    var accumulatedPlayedSeconds: TimeInterval = 0
    /// Wall-clock start of the current play segment; nil when paused or stopped.
    var currentPlaySegmentStart: Date?
    /// Set to true by handleEndOfTrack before a natural completion transition.
    var wasTrackCompletedNaturally: Bool = false
    /// Cached ISRC for the current track (server or Apple Music catalog) for Music Haptics.
    var resolvedISRCForCurrentTrack: String?
    var resolvedISRCSongId: String?
    /// Throttle Now Playing position pushes — lock-screen drift correction doesn't need 2 Hz.
    var lastNowPlayingPushDate: Date = .distantPast
    /// Bumped on pause/stop/track change so in-flight Now Playing pushes can't restore rate=1.
    var nowPlayingEpoch: UInt64 = 0
    /// Bumped on every `play()` / `startPlayback` — stale resolves and EOF handlers bail out.
    var playbackEpoch: UInt64 = 0
    var progressStallMonitor = PlaybackStallMonitor()
    /// The track the next `startPlayback` replaces. The visible track flips as soon as a tap is
    /// accepted (so the UI never waits on a network resolve), which means listening history has to
    /// read the outgoing track from here instead of `state.currentTrack`.
    var outgoingTrackForHistory: DisplayableSong?
    var outgoingPositionForHistory: TimeInterval = 0
    var outgoingSourceForHistory: MediaSource?
    /// Set from the moment a new track is accepted (and its title has flipped) until `startPlayback`
    /// takes over the engine. The progress timer must not attribute the *outgoing* engine's
    /// position, EOF or scrobble threshold to the *incoming* track during that window.
    var isTrackTransitionPending = false
    /// When the last skip/tap was accepted, so `[TRANSITION-TIMING]` can report how long the
    /// hand-over actually took (resolve vs. engine start) on a real device.
    var transitionStartedAt: Date?
    /// Buffer underruns seen for the current track, and whether the Automatic ceiling was already
    /// lowered because of them. Two underruns in one track mean the chosen rate is too high for
    /// this link; one is a hiccup.
    var underrunCountForCurrentTrack = 0
    var didAdaptQualityForCurrentTrack = false
    var lastPlaybackReportAt: Date = .distantPast
    var playbackReportSupported: Bool?

    init(
        state: PlayerState,
        mediaResolver: any MediaResolverProtocol,
        serverService: any ServerServiceProtocol,
        sessionService: PlaybackSessionService,
        artworkImageCache: ArtworkImageCache,
        lyricsService: LyricsService,
        libraryService: any LibraryServiceProtocol,
        cacheService: any CacheServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        cacheSettings: CacheSettings,
        streamingSettings: StreamingSettings,
        replayGainSettings: ReplayGainSettings,
        crossfadeSettings: CrossfadeSettings,
        gaplessSettings: GaplessSettings,
        toastService: ToastService,
        statsService: StatsService,
        listenBrainzService: ListenBrainzService,
        jellyfinService: JellyfinService? = nil,
        engine: (any PlaybackEngine)? = nil
    ) {
        self.state = state
        self.mediaResolver = mediaResolver
        self.serverService = serverService
        self.sessionService = sessionService
        self.artworkImageCache = artworkImageCache
        self.lyricsService = lyricsService
        self.libraryService = libraryService
        self.cacheService = cacheService
        self.downloadService = downloadService
        self.cacheSettings = cacheSettings
        self.streamingSettings = streamingSettings
        self.replayGainSettings = replayGainSettings
        self.crossfadeSettings = crossfadeSettings
        self.gaplessSettings = gaplessSettings
        self.toastService = toastService
        self.statsService = statsService
        self.listenBrainzService = listenBrainzService
        self.jellyfinService = jellyfinService

        let cacheConfig = URLSessionConfiguration.default
        cacheConfig.timeoutIntervalForRequest = 30
        cacheConfig.timeoutIntervalForResource = 30
        self.cacheSession = URLSession(configuration: cacheConfig)

        let prefetchConfig = URLSessionConfiguration.default
        prefetchConfig.timeoutIntervalForRequest = 30
        prefetchConfig.timeoutIntervalForResource = 300
        prefetchConfig.networkServiceType = .background
        self.prefetchSession = URLSession(configuration: prefetchConfig)

        let resolvedEngine = engine ?? AudioStreamingPlayerEngine()
        let delegate = AudioStreamingDelegate()
        self.engine = resolvedEngine
        self.audioGraph = resolvedEngine as? any AudioGraphHosting
        self.audioDelegate = delegate

        delegate.service = self
        (resolvedEngine as? any AudioStreamingPlaybackEngine)?.delegate = delegate
        systemEngine.eventHandler = { [weak self] event in
            Task { await self?.handleSystemEngineEvent(event) }
        }
        Self.installBeatMeter(on: self.audioGraph)
    }

    /// Mixer tap → `PlaybackBeatMeter` for full-player beat-reactive backgrounds.
    ///
    /// The tap is always installed: `PlaybackBeatMeter.enqueue` no-ops on a single flag check when
    /// no on-screen view is listening, and the performance budget decides whether views listen
    /// (`allowsBeatVisuals`). That keeps the cost at zero on a backgrounded / hot / Low Power
    /// device while leaving the feature intact.
    ///
    /// Skipped for an engine with no AVFoundation graph (a test fake).
    private nonisolated static func installBeatMeter(on graph: (any AudioGraphHosting)?) {
        guard let graph else { return }
        graph.addFrameFilter(named: PlaybackBeatMeter.filterName) { buffer, _ in
            // Skip band work on the audio thread when no UI is listening. The heavy
            // `bandEnergies` computation is gated inside enqueue and only runs once the
            // publish interval has elapsed, so the audio render thread does almost nothing
            // per buffer.
            PlaybackBeatMeter.enqueue(buffer: buffer)
        }
    }

    /// Call from AppContainer after both PlayerService and NowPlayingService are created.
    func setNowPlayingService(_ service: any NowPlayingServiceProtocol) {
        nowPlayingService = service
    }

    func setWidgetSyncService(_ service: WidgetSyncService) {
        widgetSyncService = service
    }

    func setReplayGainService(_ service: ReplayGainService) async {
        replayGainService = service
        await service.attach(to: audioGraph)
    }

}
