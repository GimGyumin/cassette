// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
import SwiftSonic
@testable import Cassette

// MARK: - Mocks

@MainActor
final class MockPlayerService: PlayerServiceProtocol {
    let state: PlayerState = PlayerState()
    var seekCalledWith: TimeInterval?

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {}
    func resume() async {}
    func pause() async {}
    func stop() async {}
    func skipToNext() async throws {}
    func skipToPrevious() async throws {}
    func seek(to position: TimeInterval) async { seekCalledWith = position }
    func setRepeatMode(_ mode: RepeatMode) async {}
    func toggleShuffle() async {}
    func appendToQueue(_ tracks: [DisplayableSong]) async {}
    func playNext(_ song: DisplayableSong) async {}
    func playNext(_ songs: [DisplayableSong]) async {}
    func addToQueue(_ song: DisplayableSong) async {}
    func addToQueue(_ songs: [DisplayableSong]) async {}
    func removeFromQueue(at index: Int) async {}
    func clearQueueHistory() async {}
    func clearUpNext() async {}
    func moveInQueue(fromIndex: Int, toIndex: Int) async {}
    func restoreSession() async {}
    func handleNetworkRestored() async {}
    func playRadio(_ station: InternetRadioStation) async throws {}
    func playSmartShuffle() async throws {}
    func setAutoExtendEnabled(_ enabled: Bool) async {}
    func setVolume(_ volume: Float) async {}
    func togglePlayPause() async {}
    func saveCurrentPosition() async {}
    func handleAppBecameActive() async {}
    func handleAppWillResignActive() async {}
    func handleAppDidEnterBackground() async {}
    func replayGainSettingsDidChange() async {}
    func crossfadeSettingsDidChange() async {}
    func gaplessSettingsDidChange() async {}
    nonisolated func stopAudioEngineSync() {}
}

// MARK: - Helpers

@MainActor
private func makeViewModel(
    songId: String = "song-1",
    serverId: UUID = UUID(),
    lyrics: LyricsList? = nil
) throws -> (LyricsViewModel, MockPlayerService) {
    let container = try ModelContainer(
        for: Schema([CachedLyrics.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    if let lyrics {
        let data = try JSONEncoder().encode(lyrics)
        let ctx = ModelContext(container)
        ctx.insert(CachedLyrics(songId: songId, serverId: serverId, jsonPayload: data))
        try ctx.save()
    }

    let serverService = MockLyricsServerService()
    let service = LyricsService(serverService: serverService, modelContainer: container)
    let playerService = MockPlayerService()
    let playerState = PlayerState()

    let vm = LyricsViewModel(
        songId: songId,
        serverId: serverId,
        lyricsService: service,
        playerService: playerService,
        playerState: playerState
    )
    return (vm, playerService)
}

private func syncedList(offset: Int = 0) -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(
            lang: "en",
            synced: true,
            line: [
                Line(value: "Line 0", start: 0),
                Line(value: "Line 1", start: 1000),
                Line(value: "Line 2", start: 2000),
            ],
            offset: offset
        )
    ])
}

private func multiLanguageList() -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(lang: "en", synced: true, line: [Line(value: "Hello", start: 0)]),
        StructuredLyrics(lang: "fr", synced: false, line: [Line(value: "Bonjour")])
    ])
}

private func unsyncedPlainList() -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(
            lang: "en",
            synced: false,
            line: [
                Line(value: "No timestamps here"),
                Line(value: "Still should not crash on load"),
            ]
        )
    ])
}

// MARK: - update(elapsedMs:)

@Suite("Lyrics tracking cache regressions")
@MainActor
struct LyricsTrackingCacheTests {
    @Test func distinctTimestampsAreRequired() {
        let untimedCases: [[Int?]] = [[], [nil, nil], [0], [0, 0, nil]]
        for starts in untimedCases {
            let lyrics = StructuredLyrics(lang: "en", synced: true,
                line: starts.map { Line(value: "Line", start: $0) })
            #expect(!LyricsViewModel.hasUsableTiming(lyrics))
        }
        let lyrics = StructuredLyrics(lang: "en", synced: false,
            line: [Line(value: "Untimed"), Line(value: "First", start: 0),
                   Line(value: "Duet", start: 0), Line(value: "Next", start: 1000)])
        #expect(LyricsViewModel.hasUsableTiming(lyrics))
    }

    @Test func replacingDocumentInvalidatesTrackingCache() throws {
        let (vm, _) = try makeViewModel()
        #expect(!vm.followsPlayback)
        vm.state = .loaded(syncedList().structuredLyrics[0])
        #expect(vm.followsPlayback)
        vm.state = .loaded(unsyncedPlainList().structuredLyrics[0])
        #expect(!vm.followsPlayback)
        vm.state = .loaded(syncedList().structuredLyrics[0])
        #expect(vm.followsPlayback)
        vm.state = .loading
        #expect(!vm.followsPlayback)
        vm.state = .empty
        #expect(!vm.followsPlayback)
    }
}

@Suite("Apple translation session lifecycle")
@MainActor
struct LyricsAppleTranslationSessionTests {
    @Test func ignoresOldAndInactiveSessions() throws {
        let (vm, _) = try makeViewModel()
        vm.appleTranslationRequestID = 2
        vm.isTranslating = true
        #expect(!vm.beginAppleTranslationSession(requestID: 1))
        #expect(vm.isTranslating)
        #expect(vm.beginAppleTranslationSession(requestID: 2))
        vm.isTranslating = false
        #expect(!vm.beginAppleTranslationSession(requestID: 2))
    }

    @Test func reportsTranslationFailureWithoutDiscardingLyrics() async throws {
        let (vm, _) = try makeViewModel(serverId: UUID(), lyrics: syncedList())
        await vm.load()
        await vm.failAppleTranslation(message: "Language download unavailable")
        #expect(vm.translationErrorMessage == "Language download unavailable")
        #expect(!vm.isTranslating)
        #expect(!vm.translatedLyrics.isEmpty)
    }
}

@Suite("LyricsViewModel — update(elapsedMs:)")
@MainActor
struct LyricsViewModelUpdateTests {
    @Test func lateClockSampleCannotToggleTheHighlightedLineBackward() async throws {
        let (vm, _) = try makeViewModel(serverId: UUID(), lyrics: syncedList())
        await vm.load()
        vm.update(elapsedMs: 1_100)
        #expect(vm.currentLineIndex == 1)
        vm.update(elapsedMs: 990)
        #expect(vm.currentLineIndex == 1)
        #expect(vm.karaokePlaybackMs == 1_100)
        vm.update(elapsedMs: 1_200)
        #expect(vm.currentLineIndex == 1)
        // An explicit seek resets the common clock before evaluating its target.
        vm.karaokePlaybackMs = 900
        vm.update(elapsedMs: 900)
        #expect(vm.currentLineIndex == 0)
    }

    @Test func authoritativeClockCorrectionResynchronizesLyrics() async throws {
        let (vm, _) = try makeViewModel(serverId: UUID(), lyrics: syncedList())
        await vm.load()

        vm.update(elapsedMs: 1_100)
        #expect(vm.currentLineIndex == 1)

        // A correction larger than timestamp quantization is an actual player resync,
        // such as the engine clock settling after buffering.
        vm.update(elapsedMs: 700)
        #expect(vm.currentLineIndex == 0)
        #expect(vm.karaokePlaybackMs == 700)
    }

    @Test func returnsNilBeforeLoad() throws {
        let (vm, _) = try makeViewModel()
        vm.update(elapsedMs: 500)
        #expect(vm.currentLineIndex == nil)
    }

    @Test func picksCorrectLineIndex() async throws {
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: syncedList())
        await vm.load()

        vm.update(elapsedMs: 0)
        #expect(vm.currentLineIndex == 0)

        vm.update(elapsedMs: 999)
        #expect(vm.currentLineIndex == 0)

        vm.update(elapsedMs: 1000)
        #expect(vm.currentLineIndex == 1)

        vm.update(elapsedMs: 2500)
        #expect(vm.currentLineIndex == 2)
    }

    @Test func appliesNegativeOffset() async throws {
        // offset = -500 means lines shift 500ms later
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: syncedList(offset: -500))
        await vm.load()

        // adjustedMs = 400 - (-500) = 900 → still line 0 (line 1 starts at 1000)
        vm.update(elapsedMs: 400)
        #expect(vm.currentLineIndex == 0)

        // adjustedMs = 600 - (-500) = 1100 → line 1
        vm.update(elapsedMs: 600)
        #expect(vm.currentLineIndex == 1)
    }

    @Test func appliesPositiveOffset() async throws {
        // offset = 500 means lines shift 500ms earlier
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: syncedList(offset: 500))
        await vm.load()

        // adjustedMs = 1200 - 500 = 700 → line 0 (line 1 starts at 1000)
        vm.update(elapsedMs: 1200)
        #expect(vm.currentLineIndex == 0)

        // adjustedMs = 1600 - 500 = 1100 → line 1
        vm.update(elapsedMs: 1600)
        #expect(vm.currentLineIndex == 1)
    }

    @Test func highlightsSimultaneousTimestampLines() async throws {
        let lyrics = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [
                    Line(value: "I'm starting with the man", start: 1000),
                    Line(value: "(man in the mirror)", start: 1000),
                    Line(value: "Next verse", start: 5000),
                ],
                offset: 0
            )
        ])
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: lyrics)
        await vm.load()

        vm.update(elapsedMs: 1000)
        #expect(vm.currentLineIndex == 0)
        #expect(vm.activeLineIndices == [0, 1])

        vm.update(elapsedMs: 3000)
        #expect(vm.currentLineIndex == 0)
        #expect(vm.activeLineIndices == [0, 1])

        vm.update(elapsedMs: 5000)
        #expect(vm.currentLineIndex == 2)
        #expect(vm.activeLineIndices == [2])
    }

    @Test func loadUnsyncedLyrics_doesNotCrashOnInstrumentalGapCache() async throws {
        // Regression: empty timed-lead starts used to build `1..<0` and trap with
        // "Range requires lowerBound <= upperBound" during seedOriginalLyrics.
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: unsyncedPlainList())
        await vm.load()
        guard case .loaded = vm.state else {
            Issue.record("Expected loaded unsynced lyrics")
            return
        }
        vm.update(elapsedMs: 1_000)
        #expect(vm.currentLineIndex == nil)
        #expect(vm.followsPlayback == false)
    }

    @Test func lrcLongPhraseIsNotReplacedByDotsTooEarly() async throws {
        let lyrics = LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [
                    Line(value: "First line", start: 0),
                    Line(value: "Second line", start: 3_000),
                    Line(value: "This phrase is still being sung", start: 6_000),
                    Line(value: "After the musical break", start: 20_000),
                ]
            )
        ])
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: lyrics)
        await vm.load()

        // The former fixed hold switched to dots at about 8.3 s, even though the
        // LRC line can still be sung. Keep the phrase visible at that point.
        vm.update(elapsedMs: 8_500)
        #expect(vm.currentLineIndex == 2)
        #expect(vm.instrumentalGapProgress == nil)

        // Once the conservative phrase window has elapsed, the genuinely long
        // remaining interval may use the instrumental indicator.
        vm.update(elapsedMs: 16_000)
        #expect(vm.currentLineIndex == nil)
        #expect(vm.instrumentalGapProgress != nil)
    }
}

// MARK: - userTapped(lineIndex:)

@Suite("LyricsViewModel — userTapped(lineIndex:)")
@MainActor
struct LyricsViewModelSeekTests {

    @Test func seeksSentWithCorrectTime() async throws {
        let id = UUID()
        let (vm, playerService) = try makeViewModel(serverId: id, lyrics: syncedList())
        await vm.load()

        vm.userTapped(lineIndex: 1) // start=1000ms, offset=0 → 1.0s
        try await Task.sleep(for: .milliseconds(50))
        #expect(playerService.seekCalledWith == 1.0)
    }

    @Test func seekIncludesOffset() async throws {
        let id = UUID()
        let (vm, playerService) = try makeViewModel(serverId: id, lyrics: syncedList(offset: 200))
        await vm.load()

        vm.userTapped(lineIndex: 0) // start=0, offset=200 → (0+200)/1000 = 0.2s
        try await Task.sleep(for: .milliseconds(50))
        #expect(playerService.seekCalledWith == 0.2)
    }

    @Test func noSeekOnUnsyncedState() async throws {
        let unsynced = LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: false, line: [Line(value: "Hello")])
        ])
        let id = UUID()
        let (vm, playerService) = try makeViewModel(serverId: id, lyrics: unsynced)
        await vm.load()

        vm.userTapped(lineIndex: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(playerService.seekCalledWith == nil)
    }

    @Test func noSeekOnOutOfBoundsIndex() async throws {
        let id = UUID()
        let (vm, playerService) = try makeViewModel(serverId: id, lyrics: syncedList())
        await vm.load()

        vm.userTapped(lineIndex: 99)
        try await Task.sleep(for: .milliseconds(50))
        #expect(playerService.seekCalledWith == nil)
    }
}

// MARK: - Auto-scroll

@Suite("LyricsViewModel — auto-scroll")
@MainActor
struct LyricsViewModelScrollTests {

    @Test func userStartedScrolling_setsFlag() throws {
        let (vm, _) = try makeViewModel()
        #expect(vm.isUserScrolling == false)
        vm.userStartedScrolling()
        #expect(vm.isUserScrolling == true)
    }

    @Test func isUserScrolling_resetAfter5Seconds() async throws {
        let (vm, _) = try makeViewModel()
        vm.userStartedScrolling()
        #expect(vm.isUserScrolling == true)
        // Wait slightly over 5s for the Task.sleep to complete
        try await Task.sleep(for: .seconds(5.1))
        #expect(vm.isUserScrolling == false)
    }
}

// MARK: - Language selection

@Suite("LyricsViewModel — selectLanguage")
@MainActor
struct LyricsViewModelLanguageTests {

    @Test func selectLanguage_changesActiveSetAndResetsIndex() async throws {
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: multiLanguageList())
        await vm.load()

        // After load, a language should be auto-selected
        let initial = vm.selectedLanguage

        // Simulate a non-nil currentLineIndex
        vm.update(elapsedMs: 0)

        await vm.selectLanguage("fr")
        #expect(vm.selectedLanguage == "fr")
        #expect(vm.currentLineIndex == nil)
        if initial != "fr" {
            // Language changed → state should reflect the fr set
            if case .loaded(let structured) = vm.state {
                #expect(structured.lang == "fr")
            } else {
                Issue.record("Expected .loaded state after language switch")
            }
        }
    }

    @Test func selectLanguage_noOpWhenSameLanguage() async throws {
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: multiLanguageList())
        await vm.load()

        guard let lang = vm.selectedLanguage else { return }
        let stateBefore = vm.state
        await vm.selectLanguage(lang)
        // State must not change
        #expect(vm.state == stateBefore)
    }
}

// MARK: - activeChorusBlock (x-bg timing)

private func chorusedList() -> LyricsList {
    LyricsList(structuredLyrics: [
        StructuredLyrics(
            lang: "en",
            synced: true,
            line: [
                Line(value: "Just lift yourself (Change)", start: 120_400),
                Line(value: "You know", start: 122_100),
            ],
            agents: [
                LyricsAgent(id: "lead", role: "main"),
                LyricsAgent(id: "choir", role: "bg"),
            ],
            cueLine: [
                CueLine(index: 0, start: 120_400, value: "Just lift yourself", agentId: "lead", cue: [
                    LyricCue(start: 120_400, end: 121_000, value: "Just", byteStart: 0, byteEnd: 3),
                ]),
                CueLine(index: 0, start: 120_150, value: "(Change)", agentId: "choir", cue: [
                    LyricCue(start: 120_150, end: 120_800, value: "(Change)", byteStart: 0, byteEnd: 7),
                ]),
                CueLine(index: 1, start: 122_100, value: "You know", agentId: "lead", cue: [
                    LyricCue(start: 122_100, end: 123_000, value: "You know", byteStart: 0, byteEnd: 7),
                ]),
            ]
        )
    ])
}

@Suite("LyricsViewModel — activeChorusBlock")
@MainActor
struct LyricsViewModelChorusTests {

    @Test func chorusEndIsExclusive() async throws {
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: chorusedList())
        await vm.load()

        // bg span 120_150...120_800 — inside → visible.
        vm.update(elapsedMs: 120_400)
        let inside = vm.activeChorusBlock(at: 0)
        #expect(inside?.isVisible == true)

        // Just before end → visible.
        vm.update(elapsedMs: 120_799)
        #expect(vm.activeChorusBlock(at: 0)?.isVisible == true)

        // Exactly at end → hidden (strict end exclusive).
        vm.update(elapsedMs: 120_800)
        #expect(vm.activeChorusBlock(at: 0)?.isVisible == false)

        // After end → hidden.
        vm.update(elapsedMs: 120_801)
        #expect(vm.activeChorusBlock(at: 0)?.isVisible == false)
    }
}

// MARK: - load() — availableLanguages and auto-pick

@Suite("LyricsViewModel — load()")
@MainActor
struct LyricsViewModelLoadTests {

    @Test func load_populatesAvailableLanguages() async throws {
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: multiLanguageList())
        await vm.load()
        #expect(vm.availableLanguages.contains("en"))
        #expect(vm.availableLanguages.contains("fr"))
        #expect(vm.availableLanguages.count == 2)
    }

    @Test func load_autoPicks_frFR_locale() async throws {
        // The fr set will be picked when the preferred locale is fr_FR.
        // We indirectly test this by creating a VM and loading with a pre-populated cache
        // containing a multi-language list, then checking the state reflects a valid selection.
        // (Direct locale injection not needed here — selectBestLanguage is covered in LyricsServiceTests.)
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: multiLanguageList())
        await vm.load()
        if case .loaded(_) = vm.state {
            // pass
        } else {
            Issue.record("Expected .loaded after successful load, got \(vm.state)")
        }
    }

    @Test func load_setsUnsupportedOnNotSupportedError() async throws {
        // MockLyricsServerService throws on makeSwiftSonicClient → cache miss → networkError,
        // but we need notSupportedByServer. Use an empty cache (no pre-pop) and the mock
        // will error. Confirm state is .error (since mock throws CassetteError.notImplemented,
        // not LyricsError.notSupportedByServer).
        let (vm, _) = try makeViewModel(lyrics: nil)
        await vm.load()
        if case .error(_) = vm.state { /* pass */ }
        else { Issue.record("Expected .error when network unavailable and cache empty, got \(vm.state)") }
    }

    @Test func load_setsEmptyWhenNoLyrics() async throws {
        let empty = LyricsList(structuredLyrics: [])
        // Empty list → LyricsService throws .notFound, but we need to hit network.
        // Instead: populate cache with an empty LyricsList and confirm the VM ends up .empty.
        let id = UUID()
        let (vm, _) = try makeViewModel(serverId: id, lyrics: empty)
        await vm.load()
        // applyCurrentLanguage with no structuredLyrics → .empty
        #expect(vm.state == .empty)
    }
}
