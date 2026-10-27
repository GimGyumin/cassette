// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine
import OSLog
import QuartzCore

@Observable
@MainActor
final class LyricsViewModel {

    var pronunciationRows: [[LyricDisplayWord]] = []
    @ObservationIgnored var documentBuildGeneration = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored var languageGeneration = 0
    @ObservationIgnored var translationSettingsIdentity = LyricsTranslationSettings.shared.translationIdentity

    let lyricsService: LyricsService
    let playerService: any PlayerServiceProtocol
    let playerState: PlayerState
    let songId: String
    private let serverId: UUID
    let match: LyricsMatchInfo?

    var state: State = .loading {
        didSet {
            // Document properties do not change with playback time. Never rescan
            // every timestamp from the 30/60 Hz tracking loop.
            if case .loaded(let structured) = state {
                hasTimedPlayback = Self.hasUsableTiming(structured)
                hasKaraokePlayback = structured.hasKaraokeCues
            } else {
                hasTimedPlayback = false
                hasKaraokePlayback = false
            }
        }
    }
    var hasTimedPlayback = false
    var hasKaraokePlayback = false
    /// Primary lyric row for auto-scroll (first line in a simultaneous cluster).
    var currentLineIndex: Int?
    /// All lyric rows with an active vocal stream at the current timestamp
    /// (lead + choir + ad-lib may be concurrent — Apple Music multi-track karaoke).
    var activeLineIndices: Set<Int> = []
    /// Visual lead emphasis survives short vocal gaps, ending just before the next phrase.
    var emphasizedLineIndices: Set<Int> = []
    /// Per-line inclusive UTF-8 karaoke byte ends for rows in `activeLineIndices`.
    var karaokeByteEnds: [Int: Int] = [:]
    /// Clock used for word-level karaoke progress (ms, lyrics-offset adjusted).
    var karaokePlaybackMs: Int = 0
    @ObservationIgnored var karaokeSampleHostTime: CFTimeInterval = CACurrentMediaTime()
    /// 0...1 while waiting through a long instrumental / inter-line gap; `nil` when a lyric line is active.
    var instrumentalGapProgress: Double? {
        didSet {
            let visible = instrumentalGapProgress != nil
            if hasInstrumentalGap != visible { hasInstrumentalGap = visible }
        }
    }
    private(set) var hasInstrumentalGap = false
    /// Insert the gap indicator after this lyric index (`nil` = before the first timed line).
    var instrumentalGapAfterIndex: Int?
    var instrumentalGapStartMs = 0
    var instrumentalGapEndMs = 0
    var availableLanguages: [String] = []
    /// Server-provided translation tracks (`kind=translation`) keyed by language code.
    var availableServerTranslations: [(lang: String, title: String)] = []
    /// Selected server translation language (`nil` = use client Apple/OpenAI translation).
    var selectedServerTranslationLang: String?
    var selectedLanguage: String?
    var autoScrollEnabled = true
    var isUserScrolling = false
    /// The last line index tapped by the user for seek; reset after scroll restore.
    var pendingSeekScrollIndex: Int?
    /// When true, full-player transport / toolbar collapse so lyrics can fill the screen.
    /// FullPlayerView owns the inactivity/line-transition policy; this value remains
    /// here because the layout observes it.
    var prefersHiddenChrome = false
    /// Absolute floor — never treat a long sung phrase or ordinary verse spacing as
    /// an instrumental break. LRC has starts but no trustworthy phrase ends, so a
    /// conservative floor avoids replacing a still-sung line with dots.
    nonisolated static let instrumentalGapAbsoluteFloorMs = 9_000
    /// A gap must also be clearly longer than this song’s typical line spacing.
    nonisolated static let instrumentalGapMedianMultiplier = 3.5
    /// LRC fallback bounds for estimating when a phrase has actually finished.
    nonisolated static let instrumentalGapMinimumHoldMs = 4_000
    nonisolated static let instrumentalGapMaximumHoldMs = 9_000
    nonisolated static let instrumentalGapMinimumVisibleMs = 2_000
    /// Lines whose timestamps fall within this window are treated as a simultaneous duet
    /// when building display rows; active-track exclusivity is not used (multi-track concurrent).
    nonisolated static let simultaneousLineThresholdMs = 500
    /// Expanded lead + chorus agent rows for the loaded structured lyrics.
    var displayRows: [LyricDisplayRow] = [] {
        didSet {
            playbackTimeline = LyricPlaybackTimeline(rows: displayRows)
            rebuildAMLLTimeline()
            guard let first = displayRows.first else {
                usesSpeakerLayout = false
                return
            }
            usesSpeakerLayout = displayRows.contains { $0.speakerSide != first.speakerSide }
        }
    }
    var playbackTimeline = LyricPlaybackTimeline(rows: [])
    @ObservationIgnored var emphasisTimeline = AMLLTimeline(bounds: [])
    @ObservationIgnored var emphasisDisplayIndices: [Int] = []
    @ObservationIgnored var emphasisLeadStarts: [(index: Int, startMs: Int)] = []
    @ObservationIgnored var amllTimeline = AMLLTimeline(bounds: [])
    @ObservationIgnored var amllDisplayIndices: [Int] = []
    @ObservationIgnored var amllSeekDetector = AMLLSeekDetector()
    @ObservationIgnored var amllForceSeek = true
    /// Set only on a discontinuity, so row animations do not observe the media clock.
    var amllSeekRevision = 0
    var amllTransitionIsSeek = false
    /// Canonical Apple Music–style lyric document (TTML / karaoke / LRC / plain).
    var lyricDocument: LyricDocument?
    /// Lead timed rows `(displayIndex, startMs)` for instrumental-gap detection — built once per load.
    var instrumentalTimedLeads: [(index: Int, startMs: Int)] = []
    /// Median positive gap between consecutive lead starts — built once per load.
    var instrumentalTypicalGapMs: Int = 15_000

    /// TTML songwriter credits (e.g. "작사: Michael Jackson")
    var songwritersText: String? {
        guard let doc = lyricDocument, !doc.songwriters.isEmpty else { return nil }
        return doc.songwriters.joined(separator: ", ")
    }

    /// Attribution shown below translated lyrics, matching the system lyrics presentation.
    var showsAutomaticallyGeneratedTranslationAttribution: Bool {
        guard areTranslationsVisible else { return false }
        if lyricDocument?.translations.values.contains(where: \.automaticallyCreated) == true {
            return true
        }
        return translatedLyrics.contains {
            $0.translationSource == .appleAPI || $0.translationSource == .openAI
        }
    }

    /// True when lyrics include multiple vocal agents that should use L/R layout.
    private(set) var usesSpeakerLayout = false

    /// How long after the user stops dragging before chrome / auto-scroll return.
    nonisolated static let scrollIdleSeconds: Double = 2.5

    // MARK: Translation

    var translatedLyrics: [TranslatedLyric] = []
    /// When false, translated lines stay in memory but are hidden (smooth toggle animation).
    var areTranslationsVisible = false
    /// Pronunciation / romanization is controlled independently from translations.
    var arePronunciationsVisible = false
    var isTranslating = false
    var translationErrorMessage: String?
    var translationErrorCanRetry = true
    var translationErrorOffersStandard = false
    var usesStandardTranslationForCurrentTrack = false

    var effectiveAppleIntelligencePrompt: String {
        usesStandardTranslationForCurrentTrack ? "" : LyricsTranslationSettings.shared.appleIntelligencePrompt
    }
    /// SwiftUI `.translationTask` 트리거용 — Apple 번역이 필요할 때 증가합니다.
    var appleTranslationRequestID = 0
    /// Bumped after translation content changes so LyricsView can re-center on the playing line.
    var scrollRestoreToken = 0
    /// AirPlay sheet opened while translating — finish after dismiss so Translation ↔ route picker don’t fight.
    var resumeTranslationAfterRoutePicker = false

    var translationTask: Task<Void, Error>?
    var appleTranslationTimeoutTask: Task<Void, Never>?
    var resumeTranslationTask: Task<Void, Never>?

    /// Raw TTML response body for parsing embedded Apple Music translations.
    var rawTTMLData: Data?

    var lyricsList: LyricsList?
    var trackingTask: Task<Void, Never>?
    var resumeTask: Task<Void, Never>?
    var isShown = false
    /// Rotation can overlap outgoing/incoming lyric views. Each presentation
    /// releases only its own visibility, never the new view's tracking session.
    @ObservationIgnored var visibilityOwners: Set<UUID> = []
    @ObservationIgnored var legacyVisibility = false
    /// App is foreground & active. Backgrounding must stop the 30/60Hz tracking loop —
    /// the screen is off, so advancing lyrics/karaoke is pure wasted CPU.
    var isActive = true
    /// Last discrete transport sample from the player state.
    var lastPositionSampleMs: Int = 0
    /// Wall-clock moment when `lastPositionSampleMs` was seen.
    var lastPositionSampleAt: CFTimeInterval = CACurrentMediaTime()
    /// Last transport value actually fed into lyric timing; keep monotonic except on real seeks.
    var lastDisplayedPositionMs: Int = 0
    /// True after `userTapped` pins the display position — supress `startTimer` overwrite.
    var justSeeked = false
    @ObservationIgnored var lyricSeekTask: Task<Void, Never>?
    @ObservationIgnored var lyricSeekGeneration: UInt64 = 0
    @ObservationIgnored var lyricSeekTargetMs: Int?


    nonisolated enum State: Equatable {
        case loading
        case loaded(StructuredLyrics)
        case empty
        case unsupported
        case error(String)
    }

    /// True when lyrics finished loading and have at least one non-blank line.
    var hasUsableLyrics: Bool {
        guard case .loaded(let structured) = state else { return false }
        return structured.line.contains {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Lyrics toolbar: enabled while loading (user can open) or when usable lyrics exist.
    var isLyricsButtonEnabled: Bool {
        switch state {
        case .loading: return true
        case .loaded: return hasUsableLyrics
        case .empty, .unsupported, .error: return false
        }
    }

    /// True once load finished with nothing useful — lyrics surface should dismiss.
    var shouldAutoDismissLyrics: Bool {
        switch state {
        case .empty, .unsupported, .error: return true
        case .loaded: return !hasUsableLyrics
        case .loading: return false
        }
    }


    init(
        songId: String,
        serverId: UUID,
        lyricsService: LyricsService,
        playerService: any PlayerServiceProtocol,
        playerState: PlayerState,
        match: LyricsMatchInfo? = nil
    ) {
        self.songId = songId
        self.serverId = serverId
        self.lyricsService = lyricsService
        self.playerService = playerService
        self.playerState = playerState
        self.match = match
    }


    // MARK: Load

    func load() async {
        usesStandardTranslationForCurrentTrack = false
        loadGeneration &+= 1
        let generation = loadGeneration
        guard !Task.isCancelled else { return }
        invalidateTranslationWork()
        state = .loading
        do {
            let list = try await lyricsService.fetchLyrics(
                forSongId: songId, serverId: serverId, match: match
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            let ttml = if let rawTTMLData { rawTTMLData } else {
                await lyricsService.fetchRawTTML(songId: songId, serverId: serverId)
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            lyricsList = list
            rawTTMLData = ttml
            await applyCurrentLanguage()
        } catch {
            guard generation == loadGeneration, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            switch error {
            case LyricsError.notSupportedByServer: state = .unsupported
            case LyricsError.notFound: state = .empty
            case let lyricsError as LyricsError: state = .error(networkErrorMessage(from: lyricsError))
            default: state = .error(error.localizedDescription)
            }
        }
    }
}
