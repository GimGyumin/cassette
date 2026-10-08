import Testing
import Foundation
import SwiftSonic
@testable import Cassette

/// The server/external lyrics race is decided by one pure function, so the whole arbitration table
/// is asserted here — including the timing rules that keep the lyrics screen responsive without
/// letting plain external LRC pre-empt server karaoke.
@Suite("LyricsService — source race")
struct LyricsSourceRaceTests {
    private typealias Choice = LyricsService.LyricsChoice

    private func synced(_ value: String, lang: String = "en") -> LyricsList {
        LyricsList(structuredLyrics: [
            StructuredLyrics(lang: lang, synced: true, line: [Line(value: value, start: 0)])
        ])
    }

    private func unsynced(_ value: String) -> LyricsList {
        LyricsList(structuredLyrics: [
            StructuredLyrics(lang: "en", synced: false, line: [Line(value: value)])
        ])
    }

    private func karaoke(_ value: String) -> LyricsList {
        let cue = LyricCue(start: 0, value: value, byteStart: 0, byteEnd: 4)
        return LyricsList(structuredLyrics: [
            StructuredLyrics(
                lang: "en",
                synced: true,
                line: [Line(value: value, start: 0)],
                cueLine: [CueLine(index: 0, value: value, cue: [cue])]
            )
        ])
    }

    private func empty() -> LyricsList {
        LyricsList(structuredLyrics: [])
    }

    /// "wait" (nil), "server" or "external".
    private func kind(_ choice: Choice?) -> String {
        switch choice {
        case .server: return "server"
        case .external: return "external"
        case nil: return "wait"
        }
    }

    private func decide(
        embedded: LyricsList? = nil,
        embeddedSettled: Bool = false,
        external: LyricsList? = nil,
        externalSettled: Bool = false,
        headStartElapsed: Bool = false
    ) -> String {
        kind(LyricsService.chooseSource(
            embedded: embedded,
            embeddedSettled: embeddedSettled,
            external: external,
            externalSettled: externalSettled,
            serverHeadStartElapsed: headStartElapsed
        ))
    }

    @Test("A fast external answer waits out the server head start, then wins")
    func externalWaitsForHeadStart() {
        // External arrived, server still running: hold until the head start lapses so a karaoke
        // payload from the server is not pre-empted by plain LRC.
        #expect(decide(external: synced("External"), externalSettled: true) == "wait")
        #expect(decide(external: synced("External"), externalSettled: true, headStartElapsed: true) == "external")
    }

    @Test func libraryGenerationWaitsForServerEvenAfterInteractiveDeadline() {
        #expect(LyricsService.chooseSource(
            embedded: nil, embeddedSettled: false, external: synced("External"),
            externalSettled: true, serverHeadStartElapsed: true, waitForServer: true
        ) == nil)
        #expect(kind(LyricsService.chooseSource(
            embedded: karaoke("Server"), embeddedSettled: true, external: synced("External"),
            externalSettled: true, serverHeadStartElapsed: true, waitForServer: true
        )) == "server")
        #expect(kind(LyricsService.chooseSource(
            embedded: nil, embeddedSettled: true, external: synced("External"),
            externalSettled: true, serverHeadStartElapsed: false, waitForServer: true
        )) == "external")
    }

    @Test("Once the server answered without lyrics, the external result is used immediately")
    func emptyServerDefersToExternal() {
        #expect(decide(embedded: empty(), embeddedSettled: true,
                       external: synced("External"), externalSettled: true) == "external")
    }

    @Test("Server karaoke always wins, even against external karaoke")
    func serverKaraokeWins() {
        #expect(decide(embedded: karaoke("Server"), embeddedSettled: true,
                       external: karaoke("External"), externalSettled: true, headStartElapsed: true) == "server")
    }

    @Test("External karaoke upgrades plain server lyrics")
    func externalKaraokeUpgrades() {
        #expect(decide(embedded: synced("Server"), embeddedSettled: true,
                       external: karaoke("External"), externalSettled: true, headStartElapsed: true) == "external")
    }

    @Test("External synced lyrics upgrade unsynced server lyrics")
    func syncedUpgradesUnsynced() {
        #expect(decide(embedded: unsynced("Server"), embeddedSettled: true,
                       external: synced("External"), externalSettled: true, headStartElapsed: true) == "external")
    }

    @Test("Usable server lyrics wait for a possible external upgrade, then keep priority")
    func serverLyricsKeepPriority() {
        // External still in flight — the sequential code waited for it too, so keep waiting.
        #expect(decide(embedded: synced("Server"), embeddedSettled: true) == "wait")
        // External settled without an upgrade: keep the server's (richer) payload.
        #expect(decide(embedded: synced("Server"), embeddedSettled: true,
                       external: unsynced("External"), externalSettled: true) == "server")
    }

    @Test("No lyrics anywhere keeps waiting, then reports nothing")
    func noLyricsAnywhere() {
        // Both in flight.
        #expect(decide() == "wait")
        // Both settled empty: still nothing to show — the caller keeps its error behaviour.
        #expect(decide(embedded: empty(), embeddedSettled: true,
                       external: empty(), externalSettled: true, headStartElapsed: true) == "wait")
    }

    @Test("A server failure with a fast external fallback still shows lyrics")
    func serverFailureFallsBackToExternal() {
        #expect(decide(embedded: nil, embeddedSettled: true,
                       external: synced("External"), externalSettled: true) == "external")
    }
}
