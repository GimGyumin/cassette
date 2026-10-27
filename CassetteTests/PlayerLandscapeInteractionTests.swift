import SwiftUI
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Player landscape reference and timing")
@MainActor
struct PlayerLandscapeInteractionTests {
    @Test func landscapeMatchesReferenceAndLyricsReachScreenBottom() throws {
        let size = CGSize(width: 1280, height: 588)
        let metrics = PhoneLandscapePlayerMetrics(size: size)
        #expect(metrics.artworkFrame == CGRect(x: 126, y: 85, width: 420, height: 420))
        #expect(metrics.controlsFrame.minX == 600)
        #expect(metrics.controlsFrame.maxY == 588)
        let renderer = ImageRenderer(content: PhoneLandscapePlayerColumns {
            Color.red
        } controls: {
            Color.blue
        }.frame(width: size.width, height: size.height))
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // The control/lyrics column reaches the last raster row; there is no footer-sized clip.
        #expect(pixels[((image.height - 1) * image.width + 800) * 4 + 2] > 200)
    }

    @Test func verticalAndDiagonalPansAreRejectedBeforeTrackSkipRecognition() {
        for direction in [CGSize(width: 0, height: 100), CGSize(width: 20, height: 100),
                          CGSize(width: 20, height: -100), CGSize(width: 100, height: 100), .zero] {
            #expect(!PlayerArtworkGesturePolicy.isHorizontal(velocity: direction))
        }
        #expect(PlayerArtworkGesturePolicy.isHorizontal(velocity: .init(width: 100, height: 10)))
        #expect(PlayerArtworkGesturePolicy.isHorizontal(velocity: .init(width: -100, height: 10)))
    }

    @Test func leadEmphasisWaitsForNextPhraseWithoutChangingVocalTiming() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "release", serverId: UUID(), lyricsService: container.lyricsService,
            playerService: container.playerService, playerState: container.playerState)
        let doc = try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="0" end="1"><span begin="0" end="1">First</span></p>
        <p begin="3" end="4"><span begin="3" end="4">Second</span></p>
        <p begin="12" end="13"><span begin="12" end="13">After gap</span></p>
        </div></body></tt>
        """)
        vm.lyricDocument = doc
        vm.displayRows = LyricDisplayBuilder.rows(from: doc)
        vm.state = .loaded(StructuredLyrics(lang: "en", synced: true,
            line: [Line(value: "First", start: 0), Line(value: "Second", start: 3000)]))
        vm.update(elapsedMs: 2000)
        #expect(vm.activeLineIndices.isEmpty)
        #expect(vm.emphasizedLineIndices == [0])
        vm.update(elapsedMs: 2879)
        #expect(vm.emphasizedLineIndices == [0])
        #expect(vm.currentLineIndex == 0)
        vm.update(elapsedMs: 2880)
        #expect(vm.emphasizedLineIndices.isEmpty)
        #expect(vm.currentLineIndex == 1)
        #expect(vm.activeLineIndices.isEmpty)
        vm.update(elapsedMs: 2950)
        #expect(vm.currentLineIndex == 1)
        #expect(vm.emphasizedLineIndices.isEmpty)
        vm.update(elapsedMs: 3000)
        #expect(vm.emphasizedLineIndices == [1])
        #expect(vm.currentLineIndex == 1)
        vm.update(elapsedMs: 5000)
        #expect(vm.hasInstrumentalGap && vm.emphasizedLineIndices.isEmpty)
        vm.synchronizeSeekClock(to: 2)
        #expect(vm.emphasizedLineIndices == [0])
        vm.synchronizeSeekClock(to: 2.95)
        #expect(vm.emphasizedLineIndices.isEmpty)
        #expect(vm.currentLineIndex == 1)
    }

    @Test func duetAndBackingDoNotReleaseTheLeadEarly() {
        func row(_ index: Int, _ start: Int, _ end: Int, _ agent: String, backing: Bool = false) -> LyricDisplayRow {
            LyricDisplayRow(sourceLineIndex: index, text: "Part", startMs: start, endMs: end,
                cueLine: nil, isSecondaryAgent: backing, speakerSide: .leading, agentId: agent)
        }
        let entries = LyricEmphasisTiming.entries(rows: [row(0, 0, 1000, "lead"),
            row(1, 500, 1500, "choir", backing: true), row(2, 1000, 2000, "duet"), row(3, 3000, 4000, "lead")])
        #expect(entries.first(where: { $0.index == 0 })?.end == 2880)
        #expect(entries.first(where: { $0.index == 1 })?.end == 1500)
        #expect(entries.first(where: { $0.index == 2 })?.end == 2000)
    }

    @Test func futureAndExpiredStandaloneBackingAreHidden() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "backing", serverId: UUID(), lyricsService: container.lyricsService,
            playerService: container.playerService, playerState: container.playerState)
        vm.displayRows = [LyricDisplayRow(sourceLineIndex: 0, text: "Chorus", startMs: 1000, endMs: 2000,
            cueLine: nil, isSecondaryAgent: true, speakerSide: .leading)]
        vm.hasTimedPlayback = true
        vm.currentLineIndex = 0
        #expect(vm.shouldHideStandaloneBacking(at: 0))
        vm.activeLineIndices = [0]
        #expect(!vm.shouldHideStandaloneBacking(at: 0))
        vm.activeLineIndices = []
        #expect(vm.shouldHideStandaloneBacking(at: 0))
        vm.hasTimedPlayback = false
        #expect(!vm.shouldHideStandaloneBacking(at: 0))
    }

    @Test func embeddedChorusHasNoVisibleInkBeforeItsCue() throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "embedded", serverId: UUID(), lyricsService: container.lyricsService,
            playerService: container.playerService, playerState: container.playerState)
        vm.displayRows = [LyricDisplayRow(sourceLineIndex: 0, text: "Lead", startMs: 0, endMs: 3000,
            cueLine: nil, isSecondaryAgent: false, speakerSide: .leading,
            words: [.init(text: "Chorus", startMs: 1000, endMs: 2000, role: .background)])]
        vm.hasTimedPlayback = true
        func ink(at time: Int) throws -> Int {
            vm.karaokePlaybackMs = time
            let renderer = ImageRenderer(content: LyricsBackgroundClockBlock(viewModel: vm, index: 0,
                translation: "Translation", alignment: .leading, textAlignment: .leading,
                fontSize: 24, reduceMotion: true).frame(width: 300, height: 100).background(.black))
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 20 }.count
        }
        #expect(try ink(at: 999) == 0)
        #expect(try ink(at: 1500) > 100)
        #expect(try ink(at: 2000) == 0)
        #expect(try ink(at: 0) == 0) // backward seek hides future chorus again
    }
}
