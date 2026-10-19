import Testing
import Observation
import Synchronization
import Foundation
import SwiftUI
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
