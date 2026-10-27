// Conformance tests for the AMLL Swift port, AGPL-3.0-only.
// Reference vectors generated from AMLL 5fee356362353dbb24ce9bea3a62536478040de7.
// Copyright the AMLL contributors and 2026 Cassette contributors.
import Testing
import Foundation
import SwiftUI
import SwiftSonic
@testable import Cassette

@Suite("AMLL native port conformance")
struct AMLLPortTests {
    private struct Reference: Decodable {
        struct Timeline: Decodable {
            struct Frame: Decodable {
                let time: Int, seek: Bool, playing: [Int], highlighted: [Int], scroll: Int, ended: Bool
                let gap: [Int]?
            }
            let bounds: [[Int]], frames: [Frame]
        }
        struct Seek: Decodable { let media: Double, wall: Double, playing: Bool, expected: Bool }
        struct Spring: Decodable { let interval: Double, stiffness: Double, damping: Double }
        let upstream: String
        let timelines: [Timeline], seeks: [Seek], springs: [Spring]
    }
    private func reference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/amll-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    @Test func timelineMatchesOriginalTypeScriptForOverlapsGapsAndSeeks() throws {
        let reference = try reference()
        #expect(reference.upstream == "5fee356362353dbb24ce9bea3a62536478040de7")
        for scenario in reference.timelines {
            var engine = AMLLTimeline(bounds: scenario.bounds.map { .init(start: $0[0], end: $0[1]) })
            for frame in scenario.frames {
                let value = engine.sync(frame.time, seeking: frame.seek)
                #expect(value.playing == Set(frame.playing), "playing at \(frame.time)")
                #expect(value.highlighted == Set(frame.highlighted), "highlight at \(frame.time)")
                #expect(value.scrollIndex == frame.scroll)
                #expect(value.ended == frame.ended)
                #expect(value.interlude.map { [$0.start, $0.end, $0.after] } == frame.gap)
            }
        }
    }

    @Test func seekAndSpringPoliciesMatchOriginalTypeScript() throws {
        let reference = try reference()
        var detector = AMLLSeekDetector()
        for event in reference.seeks {
            #expect(detector.detect(mediaMs: event.media, wallMs: event.wall, playing: event.playing) == event.expected)
        }
        for vector in reference.springs {
            let value = AMLLSpringPolicy.position(seeking: false, intervalMs: vector.interval)
            #expect(abs(value.stiffness - vector.stiffness) < 0.000001)
            #expect(abs(value.damping - vector.damping) < 0.000001)
        }
        detector.reset()
        let reset = detector.detect(mediaMs: 50000, wallMs: 1, playing: true)
        let invalid = detector.detect(mediaMs: .nan, wallMs: 2, playing: true)
        #expect(!reset && !invalid)
        #expect(AMLLSpringPolicy.position(seeking: true, intervalMs: 400).stiffness == 90)
        #expect(AMLLSpringPolicy.position(seeking: false, interlude: true, intervalMs: 400).damping == 15)
    }

    @Test func emphasisUsesSustainedWordsAndAudioClock() {
        #expect(AMLLGlyphStyle.shouldEmphasize(text: "빛", durationMs: 1000))
        #expect(!AMLLGlyphStyle.shouldEmphasize(text: "memories", durationMs: 2000))
        #expect(!AMLLGlyphStyle.shouldEmphasize(text: "fast", durationMs: 120))
        func style(_ time: Double, motion: Bool = true, character: Int = 0) -> AMLLGlyphStyle {
            AMLLGlyphStyle.sample(timeMs: time, startMs: 1000, endMs: 3000, fontSize: 36,
                character: character, count: 4, emphasized: true, lastWord: true, background: false, motion: motion)
        }
        #expect(style(2200).glow > 0)
        #expect(style(2200).scale > 1)
        #expect(style(2200) == style(2200)) // paused audio time is deterministic
        #expect(style(2200) != style(2200, character: 3))
        #expect(style(2200, motion: false) == AMLLGlyphStyle())
        #expect(style(9000).glow == 0 && style(9000).scale == 1)
        #expect(abs(style(9000).lift - 1.8) < 0.000001) // fill:both ordinary word float
        let inactive = style(AMLLGlyphStyle.settledTime(startMs: 1000, endMs: 3000), character: 3)
        #expect(inactive.glow == 0 && inactive.scale == 1 && inactive.shiftX == 0)
        #expect(AMLLWordMask.edge(timeMs: 1500, startMs: 1000, endMs: 2000, width: 100, fadeWidth: 18) == 50)
        #expect(AMLLWordMask.edge(timeMs: 1500, startMs: 1400, endMs: 1800, width: 100, fadeWidth: 18) == 25)
    }

    @Test func textPlanKeepsSpacesAndGroupsSyllableEmphasis() {
        let input: [AMLLTextPlan.Word] = [
            .init(text: "for", start: 0, end: 600), .init(text: "ever ", start: 600, end: 1800),
            .init(text: "빛나 ", start: 2000, end: 4000), .init(text: "👨‍👩‍👧‍👦 café", start: 4000, end: 6000)
        ]
        let plan = AMLLTextPlan.prepare(input)
        #expect(plan.map { $0.word.text }.joined() == input.map(\.text).joined())
        #expect(plan[0].group == plan[1].group && plan[0].emphasized)
        #expect(plan[0].groupEnd == 1800 && plan[1].word.start == 600)
        let cjk = plan.filter { $0.word.text == "빛" || $0.word.text == "나" }
        #expect(cjk.count == 2 && cjk[0].group != cjk[1].group)
        #expect(cjk.map { $0.word.start } == [2000, 3000])
        #expect(plan.contains { $0.word.text == "👨‍👩‍👧‍👦" })
        #expect(plan.last?.word.text == "café")
    }

    @Test func interludeBreathesAndFinishesAtTheNextVocal() {
        #expect(AMLLInterlude.sample(elapsedMs: 300, durationMs: 10000, intro: false).opacity == 0)
        #expect(AMLLInterlude.sample(elapsedMs: 300, durationMs: 10000, intro: true).opacity > 0)
        let body = AMLLInterlude.sample(elapsedMs: 2500, durationMs: 10000, intro: true)
        #expect(body.scale > 1 && body.scale <= 1.25)
        #expect(body.dots[0] > body.dots[2])
        let end = AMLLInterlude.sample(elapsedMs: 9999, durationMs: 10000, intro: true)
        #expect(end.scale < 0.5 && end.opacity < 0.02)
        #expect(AMLLInterlude.sample(elapsedMs: 10000, durationMs: 10000, intro: true).opacity == 0)
        #expect(AMLLInterlude.sample(elapsedMs: 100, durationMs: 500, intro: true).opacity == 0)
        #expect(AMLLInterlude.sample(elapsedMs: 2500, durationMs: 10000, intro: true, motion: false).scale == 1)
    }

    @Test @MainActor func appUsesPortForWordTimedDocuments() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "amll", serverId: UUID(), lyricsService: container.lyricsService,
            playerService: container.playerService, playerState: container.playerState)
        let doc = try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="0" end="1"><span begin="0" end="0.5">One </span><span begin="0.5" end="1">line</span></p>
        <p begin="3" end="4"><span begin="3" end="3.5">Next </span><span begin="3.5" end="4">line</span></p>
        <p begin="12" end="13"><span begin="12" end="12.5">After </span><span begin="12.5" end="13">gap</span></p>
        </div></body></tt>
        """)
        vm.lyricDocument = doc
        vm.displayRows = LyricDisplayBuilder.rows(from: doc)
        vm.hasTimedPlayback = true
        vm.state = .loaded(StructuredLyrics(lang: "en", synced: true, line: [Line(value: "One line", start: 0), Line(value: "Next line", start: 3000)]))
        vm.update(elapsedMs: 500)
        #expect(vm.activeLineIndices == [0])
        vm.update(elapsedMs: 2000)
        #expect(vm.activeLineIndices.isEmpty) // expired vocals dim without scrolling ahead
        #expect(vm.currentLineIndex == 0)
        vm.update(elapsedMs: 3500)
        #expect(vm.activeLineIndices == [1])
        vm.update(elapsedMs: 5000)
        #expect(vm.hasInstrumentalGap && vm.activeLineIndices.isEmpty)
        #expect(vm.instrumentalGapStartMs == 4000 && vm.instrumentalGapEndMs == 12000)
        vm.synchronizeSeekClock(to: 0.6)
        #expect(vm.activeLineIndices == [0] && !vm.hasInstrumentalGap)
        vm.displayRows = []
        vm.update(elapsedMs: 500)
        #expect(vm.activeLineIndices.isEmpty)
    }

    @Test @MainActor func expiredOverlapDimsWhileTheOtherVocalContinues() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "overlap", serverId: UUID(), lyricsService: container.lyricsService,
            playerService: container.playerService, playerState: container.playerState)
        let doc = try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="0" end="2"><span begin="0" end="2">First</span></p>
        <p begin="1" end="4"><span begin="1" end="4">Second</span></p>
        </div></body></tt>
        """)
        vm.lyricDocument = doc
        // Feed normalized overlapping backing/lead rows to the playback adapter.
        // Ordinary same-agent lead rows are intentionally clipped by the display builder.
        vm.displayRows = [
            LyricDisplayRow(sourceLineIndex: 0, text: "First", startMs: 0, endMs: 2000,
                cueLine: nil, isSecondaryAgent: true, speakerSide: .leading, preservesSourceTiming: true),
            LyricDisplayRow(sourceLineIndex: 1, text: "Second", startMs: 1000, endMs: 4000,
                cueLine: nil, isSecondaryAgent: false, speakerSide: .leading, preservesSourceTiming: true)
        ]
        vm.hasTimedPlayback = true
        vm.state = .loaded(StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "First", start: 0), Line(value: "Second", start: 1000)]))
        vm.update(elapsedMs: 1500)
        #expect(vm.activeLineIndices == [0, 1])
        vm.update(elapsedMs: 2000)
        #expect(vm.activeLineIndices == [1])
        #expect(vm.currentLineIndex == 1)
        vm.synchronizeSeekClock(to: 2.5)
        #expect(vm.activeLineIndices == [1])
        vm.synchronizeSeekClock(to: 1.5)
        #expect(vm.activeLineIndices == [0, 1])
        vm.update(elapsedMs: 4000)
        #expect(vm.activeLineIndices.isEmpty)
    }

    @Test @MainActor func bundledLicenseIsPresent() throws {
        let url = try #require(Bundle.main.url(forResource: "AMLL-AGPL-3.0", withExtension: "txt"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
    }
}
