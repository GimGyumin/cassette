import Foundation
import Testing
@testable import Cassette

@Suite("TTML semantic layers")
struct TTMLSemanticTests {
    private func document(_ body: String, head: String = "") throws -> LyricDocument {
        try AppleLyricTTMLParser.parse(string: """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:a="http://itunes.apple.com/lyric-ttml-extensions"
            xmlns:m="http://www.w3.org/ns/ttml#metadata" xmlns:s="http://www.w3.org/ns/ttml#styling" xml:lang="ko">
          <head><metadata>\(head)</metadata></head><body>\(body)</body>
        </tt>
        """)
    }

    @Test func lineTimingAndNamespaceAliases() throws {
        let doc = try document("<div a:song-part=\"Chorus\"><p begin=\"2s\" dur=\"1500ms\" a:key=\"L1\" m:agent=\"v2\">Hello <span>world</span>!</p></div>")
        let line = try #require(doc.allLines.first)
        #expect(doc.timing == .line)
        #expect(line.displayText == "Hello world!")
        #expect(line.begin == 2)
        #expect(line.end == 3.5)
        #expect(line.agentId == "v2")
        #expect(line.key == "L1")
        #expect(doc.sections.first?.songPart == "Chorus")
    }

    @Test func plainLyricsAreNotDiscardedOrTimed() throws {
        let doc = try document("<p>First &amp; second<br/>Next</p>")
        #expect(doc.timing == .none)
        #expect(doc.allLines.first?.displayText == "First & second\nNext")
        #expect(LyricDisplayBuilder.rows(from: doc).first?.startMs == nil)
    }

    @Test func literalKoreanSpacesAndAdjacentSyllablesSurvive() throws {
        let doc = try document("<p begin=\"1\" end=\"5\"><span begin=\"1\" end=\"2\">시</span><span begin=\"2\" end=\"3\">작은 </span><span begin=\"3\" end=\"5\">나</span></p>")
        #expect(doc.allLines.first?.displayText == "시작은 나")
        let row = try #require(LyricDisplayBuilder.rows(from: doc).first)
        #expect(row.words.map(\.text).joined() == "시작은 나")
        #expect(row.words.allSatisfy { $0.preservesSourceSpacing })
    }

    @Test func nestedTimingDoesNotLoseOuterTextOrMergeBacking() throws {
        let doc = try document("""
        <p begin="1" end="6"><span m:role="x-bg" m:agent="v2" begin="1" end="3">(oh)</span><span begin="2" end="6">heart<span begin="3" end="4">break</span>er</span></p>
        """)
        let line = try #require(doc.allLines.first)
        #expect(line.displayText == "heartbreaker")
        #expect(line.backgroundWords.map(\.text).joined() == "(oh)")
        #expect(line.backgroundWords.first?.agentId == "v2")
        #expect(line.mainWords.map(\.text) == ["heart", "break", "er"])
    }

    @Test func independentTranslationsAndTimedPronunciations() throws {
        let head = """
        <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations>
        <translation xml:lang="en"><text for="L1">Hello<span m:role="x-bg">(hey)</span></text></translation>
        <translation xml:lang="ko"><text for="L1">안녕<span m:role="x-bg">(안녕)</span></text></translation>
        </translations><transliterations><transliteration xml:lang="ko-Latn" automaticallyCreated="true">
        <text for="L1"><span begin="1" end="2">an</span><span begin="2" end="3">nyeong</span><span m:role="x-bg"><span begin="2" end="3">(hey)</span></span></text>
        </transliteration></transliterations></iTunesMetadata>
        """
        var doc = try document("<p a:key=\"L1\" begin=\"1\" end=\"3\">안녕<span m:role=\"x-bg\">(헤이)</span></p>", head: head)
        doc.selectTranslation(preferredLanguages: ["ko-KR"])
        #expect(doc.translations.count == 1)
        #expect(doc.translations["L1"]?.main == "안녕")
        #expect(doc.translations["L1"]?.background == "(안녕)")
        #expect(doc.translationsByLanguage["en"]?["L1"]?.main == "Hello")
        let pronunciation = try #require(doc.pronunciation(for: "L1"))
        #expect(pronunciation.main == "annyeong")
        #expect(pronunciation.background == "(hey)")
        #expect(pronunciation.words.first?.begin == 1)
        #expect(pronunciation.automaticallyCreated)
        #expect(doc.allLines.first?.mainWords.map(\.text).joined() == "안녕")
    }

    @Test func inlineLocalizationDoesNotBecomeSungText() throws {
        let doc = try document("<p begin=\"1\" end=\"3\">Hello<span m:role=\"x-translation\" xml:lang=\"ko\">안녕</span><span m:role=\"x-roman\" xml:lang=\"en-Latn\">hello</span></p>")
        let line = try #require(doc.allLines.first)
        let key = try #require(line.key)
        #expect(line.displayText == "Hello")
        #expect(doc.translations[key]?.main == "안녕")
        #expect(doc.pronunciation(for: key)?.main == "hello")
    }

    @Test func rubyIsPreservedWithoutDuplicatingTheBase() throws {
        let doc = try document("<p begin=\"1\" end=\"3\"><span s:ruby=\"container\"><span s:ruby=\"base\">所</span><span s:ruby=\"textContainer\"><span s:ruby=\"text\">しょ</span></span></span></p>")
        #expect(doc.allLines.first?.displayText == "所")
        #expect(doc.allLines.first?.words.first?.ruby == "しょ")
    }

    @Test func nestedSectionsAndGroupPerformer() throws {
        let doc = try document("<div a:song-part=\"Verse\"><p begin=\"1\" end=\"2\" m:agent=\"v1\">A</p><div a:song-part=\"Chorus\"><p begin=\"2\" end=\"3\" m:agent=\"v3\">B</p></div><p begin=\"3\" end=\"4\">C</p></div>", head: "<m:agent xml:id=\"v1\" type=\"person\"/><m:agent xml:id=\"v3\" type=\"group\"/>")
        #expect(doc.allLines.map(\.displayText) == ["A", "B", "C"])
        #expect(doc.sections.map(\.songPart) == ["Verse", "Chorus", "Verse"])
        #expect(LyricDisplayBuilder.rows(from: doc)[1].speakerSide == .center)
    }

    @Test func backgroundOverlapIsNotClippedToNextLead() throws {
        let doc = try document("<p begin=\"1\" end=\"5\" m:role=\"x-bg\">(oh)</p><p begin=\"3\" end=\"6\">Lead</p>")
        #expect(LyricDisplayBuilder.rows(from: doc).first?.endMs == 5000)
    }

    @Test func malformedAndEmptyDocumentsFail() {
        #expect(throws: (any Error).self) { try AppleLyricTTMLParser.parse(string: "<tt><body><p>") }
        #expect(throws: (any Error).self) { try AppleLyricTTMLParser.parse(string: "<tt><body/></tt>") }
        #expect(LyricTime.parse("NaN") == nil)
        #expect(LyricTime.parse("inf") == nil)
        #expect(LyricTime.parse("-1s") == nil)
        #expect(LyricTime.parse("250ms") == 0.25)
        #expect(LyricTime.parse("1e308h") == nil)
    }

    @Test func instrumentalSectionsRemainMetadata() throws {
        let doc = try document("<div a:song-part=\"Instrumental\" begin=\"0\" end=\"5\"/><div a:song-part=\"Verse\"><p begin=\"5\" end=\"7\">Hello</p></div>")
        #expect(doc.sections.first?.songPart == "Instrumental")
        #expect(doc.sections.first?.lines.isEmpty == true)
        #expect(LyricDisplayBuilder.rows(from: doc).map(\.text) == ["Hello"])
    }

    @Test func spanTimesAreClippedToTheirParagraph() throws {
        let doc = try document("<p begin=\"2\" end=\"4\"><span begin=\"1\" end=\"6\">Hello</span><span begin=\"7\" end=\"8\">invalid</span></p>")
        let line = try #require(doc.allLines.first)
        #expect(line.words.count == 1)
        #expect(line.words.first?.begin == 2)
        #expect(line.words.first?.end == 4)
    }
}

@Suite("Now Playing artwork revision")
struct NowPlayingArtworkRevisionTests {
    @Test @MainActor func lateCoverCannotReplaceANewerTrackOrStoppedSession() {
        let revision = NowPlayingArtworkRevision()
        #expect(revision.accept(1))
        #expect(revision.accept(2))
        #expect(!revision.matches(1))
        #expect(!revision.accept(1))
        #expect(revision.matches(2))
        #expect(revision.accept(3))
        #expect(!revision.matches(2))
    }

    @Test func songIdentifierBackfillsMissingRecommendationArtworkIdentifier() {
        let snapshot = NowPlayingSnapshot(
            title: "Autoplay result",
            artist: "Artist",
            album: "Album",
            duration: 180,
            position: 0,
            playbackRate: 1,
            artworkURL: nil,
            artworkHeaders: [:],
            coverArtId: nil,
            isLiveStream: false,
            radioStationName: nil,
            isrc: nil,
            trackId: "song-id"
        )

        #expect(snapshot.effectiveCoverArtId == "song-id")
    }
}
