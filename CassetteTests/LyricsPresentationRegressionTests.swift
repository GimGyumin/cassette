import Testing
import Observation
import Synchronization
import Foundation
import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Cassette

@Suite("Lyrics presentation and spacing")
struct LyricsPresentationRegressionTests {
    @Test("Gap fill ticks do not invalidate the lyrics list membership") @MainActor
    func gapFillUpdatesOnlyTheProgressLeaf() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let vm = LyricsViewModel(songId: "gap", serverId: UUID(), lyricsService: container.lyricsService,
                                 playerService: container.playerService, playerState: container.playerState)
        vm.instrumentalGapProgress = 0
        let listChanges = Mutex(0)
        let leafChanges = Mutex(0)
        withObservationTracking { _ = vm.hasInstrumentalGap } onChange: { listChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = vm.instrumentalGapProgress } onChange: { leafChanges.withLock { $0 += 1 } }
        for tick in 1...100 { vm.instrumentalGapProgress = Double(tick) / 100 }
        #expect(listChanges.withLock { $0 } == 0)
        #expect(leafChanges.withLock { $0 } == 1)
        vm.instrumentalGapProgress = nil
        #expect(listChanges.withLock { $0 } == 1)
        #expect(!vm.hasInstrumentalGap)
    }

    @Test("Prepared artwork palette replaces a provisional gray player color") @MainActor
    func preparedPaletteWinsOverLegacyGray() async throws {
        let extractor = DominantColorExtractor()
        let id = "palette-priority-\(UUID())"
        _ = extractor.storeColor(packed: 0x777777, for: id)
        let image = try #require(ArtworkImageCache.thumbnailImage(from: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==")!, maxDimension: 64))
        let palette = try #require(AlbumColorAnalyzer.generateArtworkPalette(from: image))
        ColorCache.store(palette, for: id)
        let vm = FullPlayerViewModel()
        await vm.updateColors(for: id, colorExtractor: extractor, container: nil)
        let expected = ArtworkColorTransformer.player(from: RawArtworkColorAnalysis(color: palette.background))
        #expect(vm.dominantColor == expected.base)
    }

    @Test("Zero-duration separators survive TTML and display-row adaptation",
          arguments: ["Liberian Girl", "my world", "리베리안 걸", "너와 나"])
    func zeroDurationSpaces(source: String) throws {
        let tokens = source.split(separator: " ")
        let document = try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:space="preserve"><body><p begin="1" end="4"><span begin="1" end="2">\(tokens[0])</span><span begin="2" end="2"> </span><span begin="2" end="4">\(tokens[1])</span></p></body></tt>
        """)
        let row = try #require(LyricDisplayBuilder.rows(from: document).first)
        #expect(row.text == source)
        #expect(row.words.map(\.text).joined() == source)
        #expect(row.words.map(\.startMs) == [1000, 2000, 2000])
    }

    @Test("Normal delimiters and glued syllables retain their original boundaries")
    func literalBoundaries() throws {
        let document = try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><p begin="1" end="4"><span begin="1" end="2">Li</span><span begin="2" end="3">berian </span><span begin="3" end="4">Girl</span></p></body></tt>
        """)
        let words = try #require(LyricDisplayBuilder.rows(from: document).first).words
        #expect(words.map(\.text) == ["Li", "berian ", "Girl"])
        #expect(words.map { LyricKaraokeSpacing.visibleText($0.text) }.joined() == "Liberian\u{00A0}Girl")
    }

    @Test("Trailing token spaces occupy visible SwiftUI layout width") @MainActor
    func measuredSeparator() throws {
        func width(_ string: String) throws -> CGFloat {
            let renderer = ImageRenderer(content: Text(verbatim: LyricKaraokeSpacing.visibleText(string))
                .font(.system(size: 34, weight: .heavy)).fixedSize())
            #if os(iOS)
            return try #require(renderer.uiImage).size.width
            #else
            return try #require(renderer.nsImage).size.width
            #endif
        }
        #expect(try width("Liberian ") > width("Liberian") + 4)
        #expect(try width("my ") > width("my") + 4)
    }

    @Test("Primary Now Playing title does not change after theme preparation") @MainActor
    func stableTitle() async throws {
        let vm = FullPlayerViewModel()
        let initial = vm.contentColor
        await vm.updateColors(for: nil, colorExtractor: DominantColorExtractor(), container: nil)
        #expect(vm.contentColor == initial)
        #expect(CassetteColors.sRGBLuminance(of: vm.contentColor)! > 0.9)
    }

    @Test("Reopening Now Playing retains the exact prepared cover and theme") @MainActor
    func reopeningRetainsPreparedTheme() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let server = ServerConfig(displayName: "Reopen", baseURL: "https://example.invalid", username: "test")
        container.serverState.activeServer = ServerSnapshot(from: server)
        let coverID = "reopen-\(UUID())"
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        await container.downloadService.persistCover(data, forId: coverID)
        defer { Task { await container.downloadService.removeCover(forId: coverID) } }
        let firstPresentation = container.fullPlayerViewModel
        await firstPresentation.updateColors(for: coverID, colorExtractor: container.dominantColorExtractor, container: container)
        let image = try #require(firstPresentation.coverImage(for: coverID))
        let color = try #require(firstPresentation.themeColor(for: coverID, serverID: server.id))
        container.artworkImageCache.clearCache()
        let secondPresentation = container.fullPlayerViewModel
        #expect(firstPresentation === secondPresentation)
        #expect(secondPresentation.coverImage(for: coverID) === image)
        #expect(secondPresentation.themeColor(for: coverID, serverID: server.id) == color)
        await secondPresentation.updateColors(for: coverID, colorExtractor: container.dominantColorExtractor, container: container)
        #expect(secondPresentation.coverImage(for: coverID) === image)
        #expect(secondPresentation.themeColor(for: coverID, serverID: server.id) == color)
        #expect(secondPresentation.themeColor(for: "other-cover", serverID: server.id) == nil)
        #expect(secondPresentation.themeColor(for: coverID, serverID: UUID()) == nil)
        await secondPresentation.updateColors(for: coverID, colorExtractor: container.dominantColorExtractor, container: container, uploadVersion: 1)
        let refreshedImage = try #require(secondPresentation.coverImage(for: coverID))
        #expect(refreshedImage !== image)
        secondPresentation.resetTheme()
        #expect(secondPresentation.coverImage(for: coverID) == nil)
        #expect(secondPresentation.themeColor(for: coverID, serverID: server.id) == nil)
    }

}

@Suite("Timed glyph presentation")
struct LyricGlyphPresentationTests {
    @Test func clockFreezesOnPauseAndBoundsExtrapolation() {
        #expect(LyricPresentationClock.time(sampleMs: 1000, sampledAt: 5, now: 5.02, advancing: true) == 1019
            || LyricPresentationClock.time(sampleMs: 1000, sampledAt: 5, now: 5.02, advancing: true) == 1020)
        #expect(LyricPresentationClock.time(sampleMs: 1000, sampledAt: 5, now: 8, advancing: true) == 1080)
        #expect(LyricPresentationClock.time(sampleMs: 1000, sampledAt: 5, now: 8, advancing: false) == 1000)
        #expect(LyricPresentationClock.time(sampleMs: 1000, sampledAt: 5, now: 4, advancing: true) == 1000)
        #expect(LyricPresentationClock.time(sampleMs: 250, sampledAt: 8, now: 8, advancing: true) == 250)
    }

    @Test func distantSeekJumpsWhileNearbyHandoffsAnimate() {
        #expect(LyricScrollTiming.duration(previous: 2, target: 30, seeking: true, reduceMotion: false) == nil)
        #expect(LyricScrollTiming.duration(previous: 30, target: 2, seeking: true, reduceMotion: false) == nil)
        #expect(LyricScrollTiming.duration(previous: nil, target: 30, seeking: false, reduceMotion: false) == nil)
        #expect(LyricScrollTiming.duration(previous: 2, target: 3, seeking: false, reduceMotion: false) == 0.46)
        #expect(LyricScrollTiming.duration(previous: 2, target: 3, seeking: true, reduceMotion: false) == 0.22)
        #expect(LyricScrollTiming.duration(previous: 2, target: 3, seeking: false, reduceMotion: true) == nil)
    }

    @Test(arguments: [["Li", "berian ", "Girl"], ["cannot", " ", "lie"], ["know", " ", "why"], ["Love ", "is", " ", "strong"]])
    @MainActor func sourceSyllableTokensDoNotAddVisualSpaces(parts: [String]) throws {
        func inkWidth(_ words: [LyricDisplayWord], name: String) throws -> Int {
            let renderer = ImageRenderer(content: LyricWordKaraokeLine(words: words, adjustedMs: 2000,
                fontSize: 34, reduceMotion: true).frame(width: 340).padding(8).background(.black))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var left = image.width, right = 0
            for y in 0..<image.height {
                for x in 0..<image.width where pixels[(y * image.width + x) * 4] > 150 {
                    left = min(left, x); right = max(right, x)
                }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return right - left
        }
        let split = parts.map {
            LyricDisplayWord(text: $0, startMs: 0, endMs: 1000, role: .main, preservesSourceSpacing: true)
        }
        let whole = [LyricDisplayWord(text: parts.joined(), startMs: 0, endMs: 1000, role: .main, preservesSourceSpacing: true)]
        let splitWidth = try inkWidth(split, name: "cassette-ttml-syllables.png")
        let wholeWidth = try inkWidth(whole, name: "cassette-ttml-word.png")
        // Small kerning differences are allowed, renderer padding must not become spaces.
        #expect(abs(splitWidth - wholeWidth) <= 6)
    }

    @Test func chromeExpansionKeepsActiveVerseAtTheSamePhysicalHeight() {
        for rowHeight: CGFloat in [44, 88, 148, 210] {
            let compact = LyricScrollGeometry.anchor(viewportHeight: 370, bottomInset: 8, rowHeight: rowHeight)
            let expanded = LyricScrollGeometry.anchor(viewportHeight: 650, bottomInset: 8, rowHeight: rowHeight)
            #expect(abs((370 - rowHeight) * compact - 64) < 0.01)
            #expect(abs((650 - rowHeight) * expanded - 64) < 0.01)
        }
        #expect(LyricScrollGeometry.anchor(viewportHeight: 120, bottomInset: 8, rowHeight: 200) == 0)
        #expect(LyricScrollGeometry.anchor(viewportHeight: 0, bottomInset: 0, rowHeight: 0) == 0)
    }

    @Test(arguments: ["I'm tellin' you on how I feel, ah", "Just show your stuff or let it be, ah",
                      "There's a place in your heart, and I know that it is love"], [0, 1, 2])
    @MainActor func timedSpansUseNativeParagraphWrapping(phrase: String, alignmentIndex: Int) throws {
        let alignment: TextAlignment = [.leading, .center, .trailing][alignmentIndex]
        let frameAlignment: Alignment = [.leading, .center, .trailing][alignmentIndex]
        let tokens = phrase.split(separator: " ").enumerated().map { index, part in
            LyricDisplayWord(text: String(part) + " ", startMs: index * 100, endMs: index * 100 + 100,
                role: .main, preservesSourceSpacing: true)
        }
        let source = tokens.map(\.text).joined()
        let timed = LyricWordKaraokeLine(words: tokens, adjustedMs: 10000, fontSize: 36,
            textAlignment: alignment, reduceMotion: true)
            .frame(width: 338).padding(16).background(.black)
        let plain = Text(verbatim: source).font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
            .lineSpacing(2).multilineTextAlignment(alignment).fixedSize(horizontal: false, vertical: true)
            .frame(width: 338, alignment: frameAlignment).padding(16).background(.black)
        let timedRenderer = ImageRenderer(content: timed)
        let plainRenderer = ImageRenderer(content: plain)
        timedRenderer.scale = 2; plainRenderer.scale = 2
        let actual = try #require(timedRenderer.cgImage), expected = try #require(plainRenderer.cgImage)
        #expect(actual.width == expected.width && actual.height == expected.height)
        func inkRows(_ image: CGImage) throws -> [(left: Int, right: Int)] {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (0..<image.height).map { y in
                let ink = (0..<image.width).filter { pixels[(y * image.width + $0) * 4] > 150 }
                return (ink.first ?? 0, ink.last ?? 0)
            }
        }
        let actualRows = try inkRows(actual), expectedRows = try inkRows(expected)
        #expect(actualRows.count == expectedRows.count)
        // Filled glyphs composite dim + bright edges. Compare visual line bounds,
        // not a threshold contour on one antialiased row at the glyph baseline.
        func bands(_ rows: [(left: Int, right: Int)]) -> [CGRect] {
            var result: [CGRect] = []
            var start: Int?, left = Int.max, right = 0
            for (y, row) in (rows + [(0, 0)]).enumerated() {
                if row.right > row.left {
                    if start == nil { start = y }
                    left = min(left, row.left); right = max(right, row.right)
                } else if let first = start {
                    result.append(CGRect(x: left, y: first, width: right - left, height: y - first))
                    start = nil; left = Int.max; right = 0
                }
            }
            return result
        }
        let actualBands = bands(actualRows), expectedBands = bands(expectedRows)
        #expect(actualBands.count == expectedBands.count && actualBands.count >= 2)
        for (actualBand, expectedBand) in zip(actualBands, expectedBands) {
            #expect(abs(actualBand.minX - expectedBand.minX) <= 2)
            #expect(abs(actualBand.maxX - expectedBand.maxX) <= 2)
            #expect(abs(actualBand.minY - expectedBand.minY) <= 2)
            #expect(abs(actualBand.height - expectedBand.height) <= 2)
            #expect(abs(actualBand.width - expectedBand.width) <= 2)
        }
        let phraseID = phrase.hasPrefix("I'm") ? "a" : phrase.hasPrefix("Just") ? "b" : "screenshot"
        let suffix = "\(phraseID)-\(alignmentIndex)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-native-paragraph-\(suffix).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, actual, nil)
        #expect(CGImageDestinationFinalize(destination))
        let plainURL = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-native-plain-\(suffix).png")
        let plainDestination = try #require(CGImageDestinationCreateWithURL(plainURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(plainDestination, expected, nil)
        #expect(CGImageDestinationFinalize(plainDestination))
    }

    @Test @MainActor func glyphMaskProgressAndLongTokenWrapping() throws {
        func rendered(_ time: Int, width: CGFloat = 340, text: String = "우리의 memories") throws -> CGImage {
            let word = LyricDisplayWord(text: text, startMs: 0, endMs: 1000, role: .main)
            let renderer = ImageRenderer(content:
                LyricWordKaraokeLine(words: [word], adjustedMs: time, fontSize: 34, reduceMotion: true)
                    .frame(width: width).padding(8).background(.black))
            renderer.scale = 1
            return try #require(renderer.cgImage)
        }
        func brightness(_ image: CGImage) throws -> Int {
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
        }
        let dim = try rendered(0), half = try rendered(500), full = try rendered(1000)
        #expect(try brightness(half) > brightness(dim) * 12 / 10)
        #expect(try brightness(full) > brightness(half) * 12 / 10)
        #expect(dim.width == half.width && half.height == full.height)
        let long = "아름다운우리의기억들을오랫동안간직할거야"
        let narrow = try rendered(500, width: 160, text: long)
        let wide = try rendered(500, width: 600, text: long)
        #expect(narrow.width == 176 && narrow.height > wide.height)

        let fixture = ImageRenderer(content: VStack(alignment: .leading, spacing: 24) {
            ForEach([0, 250, 500, 750, 1000, 1320], id: \.self) { time in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(time) ms").font(.system(size: 12, design: .monospaced)).frame(width: 70)
                    LyricWordKaraokeLine(words: [LyricDisplayWord(text: "우리의 memories", startMs: 0, endMs: 1000, role: .main)],
                        adjustedMs: time, fontSize: 34)
                }
            }
        }.foregroundStyle(.white).padding(24).frame(width: 460).background(Color(white: 0.16)))
        fixture.scale = 2
        let image = try #require(fixture.cgImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassette-ttml-glyphs.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
