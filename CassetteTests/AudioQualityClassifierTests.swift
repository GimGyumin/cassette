import Testing
import Foundation
@testable import Cassette

@Suite("AudioQualityClassifier")
struct AudioQualityClassifierTests {
    @Test("Multichannel has its own album and playback label")
    func multichannelLabel() {
        let song = DisplayableSong(id: "surround", title: "Music", audioFormat: "flac", channelCount: 6)
        #expect(AudioQualityClassifier.classify(song) == .multichannel(channels: 6, codec: nil))
        #expect(AudioQualityClassifier.bestQuality(in: [song]) == .multichannel(channels: 6, codec: nil))
        #expect(AudioQualityClassifier.isSpatialOrMultichannel(song))
        // Surround is bitstreamed raw, so the badge survives a request that still
        // reports transcoding (and a cellular network).
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: true, isTranscoding: false) == .multichannel(channels: 6, codec: nil))
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: false, isTranscoding: true) == .multichannel(channels: 6, codec: nil))
    }

    @Test("Dolby surround gets a Dolby label even without Atmos metadata", arguments: [
        ("ac3", "Dolby Digital"),
        ("eac3", "Dolby Digital Plus"),
        ("ec3", "Dolby Digital Plus"),
        ("thd", "Dolby TrueHD"),
    ])
    func dolbySurroundLabels(_ format: String, _ codec: String) {
        let song = DisplayableSong(id: "dolby", title: "Music", audioFormat: format, channelCount: 6)
        #expect(AudioQualityClassifier.classify(song) == .dolby(codec: codec, channels: 6))
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: true, isTranscoding: true) == .dolby(codec: codec, channels: 6))
        #expect(!AudioQualityClassifier.usesAtmosSpatialization(song))
    }

    @Test("DTS is described as multichannel with its codec")
    func dtsLabel() {
        let song = DisplayableSong(id: "dts", title: "Music", audioFormat: "dts", channelCount: 6)
        let kind = AudioQualityClassifier.classify(song)
        guard case .multichannel(let channels, let codec) = kind else {
            Issue.record("Expected multichannel, got \(String(describing: kind))")
            return
        }
        #expect(channels == 6)
        #expect(codec == "DTS")
    }

    @Test("JOC comment marks an E-AC-3 core as Atmos")
    func jocIsAtmos() {
        let song = DisplayableSong(id: "joc", title: "Music", audioFormat: "eac3", channelCount: 2, comment: "JOC")
        #expect(AudioQualityClassifier.classify(song) == .dolbyAtmos)
        #expect(AudioQualityClassifier.usesAtmosSpatialization(song))
    }

    @Test("Channel layout uses Apple's 5.1 / 7.1 shorthand")
    func channelLayoutLabels() {
        #expect(AudioQualityKind.channelLayout(6) == "5.1")
        #expect(AudioQualityKind.channelLayout(8) == "7.1")
        #expect(AudioQualityKind.channelLayout(0) == nil)
        // Any other count is a localized "N channels" label, so only its presence is asserted.
        #expect(AudioQualityKind.channelLayout(4)?.isEmpty == false)
        #expect(AudioQualityKind.channelLayout(2)?.isEmpty == false)
    }

    @Test("Surround detail line combines layout and codec")
    func surroundDetailLine() {
        #expect(AudioQualityKind.dolby(codec: "Dolby Digital Plus", channels: 6).detailLine == "5.1 · Dolby Digital Plus")
        #expect(AudioQualityKind.multichannel(channels: 0, codec: "DTS").detailLine == "DTS")
    }

    @Test("Album badge prefers Atmos, then Dolby, then surround, then lossless")
    func bestQualityRanking() {
        let atmos = DisplayableSong(id: "atmos", title: "A", genre: "Dolby Atmos", channelCount: 6)
        let dolby = DisplayableSong(id: "dolby", title: "B", audioFormat: "eac3", channelCount: 6)
        let surround = DisplayableSong(id: "surround", title: "C", audioFormat: "flac", channelCount: 6)
        let lossless = DisplayableSong(id: "flac", title: "D", audioFormat: "flac", bitDepth: 16, samplingRate: 44_100)
        #expect(AudioQualityClassifier.bestQuality(in: [lossless, surround, dolby, atmos]) == .dolbyAtmos)
        #expect(AudioQualityClassifier.bestQuality(in: [lossless, surround, dolby]) == .dolby(codec: "Dolby Digital Plus", channels: 6))
        #expect(AudioQualityClassifier.bestQuality(in: [lossless, surround]) == .multichannel(channels: 6, codec: nil))
    }

    @Test("Album header keeps spatial and lossless masters visible together")
    func albumQualityBadges() {
        let atmos = DisplayableSong(id: "atmos", title: "A", genre: "Dolby Atmos", channelCount: 6)
        let hiRes = DisplayableSong(
            id: "hires",
            title: "B",
            audioFormat: "flac",
            bitDepth: 24,
            samplingRate: 96_000,
            channelCount: 2
        )
        #expect(AudioQualityClassifier.albumQualities(in: [hiRes, atmos]) == [
            .dolbyAtmos,
            .hiResLossless(bitDepth: 24, sampleRate: 96_000, formatLabel: "FLAC")
        ])
    }

    @Test("Lossless badge follows the stream codec on Wi-Fi and cellular")
    func losslessBadgeGating() {
        let song = DisplayableSong(id: "flac", title: "Music", audioFormat: "flac", bitDepth: 16, samplingRate: 44_100)
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: false, isTranscoding: false) != nil)
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: true, isTranscoding: false) != nil)
        #expect(AudioQualityClassifier.displayablePlaybackQuality(for: song, isExpensive: false, isTranscoding: true) == nil)
    }

    @Test func streamQualityUsesCodecInsteadOfUniversalEndpointName() throws {
        let routes: [(String, Bool)] = [
            ("/Audio/song/universal?AudioCodec=flac&Static=false", true),
            ("/Audio/song/universal?audiocodec=ALAC", true),
            ("/Audio/song/universal?AudioCodec=aac&Static=false", true),
            ("/Audio/song/universal?Static=true", false),
            ("/Audio/song/main.m3u8?AudioCodec=aac", true),
            ("/rest/stream?format=raw", false),
            ("/rest/stream?format=aac", true),
        ]
        for (route, isLossy) in routes {
            let url = try #require(URL(string: "https://music.example.com" + route))
            #expect(AudioQualityClassifier.isLossyTranscodeStream(.stream(url, customHeaders: [:])) == isLossy)
        }
    }

    @Test("Lossy stereo codecs have no quality label", arguments: ["mp3", "aac", "opus", "ogg", "wma"])
    func lossyStereoHasNoLabel(_ format: String) {
        let song = DisplayableSong(id: "lossy", title: "Music", audioFormat: format, channelCount: 2)
        #expect(AudioQualityClassifier.classify(song) == nil)
        #expect(AudioQualityClassifier.bestQuality(in: [song]) == nil)
        #expect(!AudioQualityClassifier.isSpatialOrMultichannel(song))
    }

    @Test("Stereo AC3 is labelled as Dolby, not as discrete multichannel")
    func stereoSurroundCodec() {
        let song = DisplayableSong(id: "stereo", title: "Music", audioFormat: "ac3", channelCount: 2)
        #expect(AudioQualityClassifier.classify(song) == .dolby(codec: "Dolby Digital", channels: 2))
        #expect(!AudioQualityClassifier.isSpatialOrMultichannel(song))
    }
    @Test("Surround codecs are preserved without inventing Atmos metadata", arguments: ["ac3", "eac3", "dts"])
    func surroundIsNotAlwaysAtmos(_ format: String) {
        let song = DisplayableSong(id: "surround", title: "Surround", audioFormat: format, channelCount: 6)
        #expect(AudioQualityClassifier.requiresSystemPlayer(song))
        #expect(AudioQualityClassifier.shouldSkipTranscoding(song))
        #expect(!AudioQualityClassifier.usesAtmosSpatialization(song))
        #expect(AudioQualityClassifier.classify(song) != .dolbyAtmos)
    }

    @Test("Ambiguous MP4 is preserved but high bitrate alone does not mean Atmos")
    func ambiguousMP4() {
        let song = DisplayableSong(id: "mp4", title: "Music", audioFormat: "m4a", contentType: "audio/mp4", bitRate: 900, channelCount: 2)
        #expect(AudioQualityClassifier.requiresSystemPlayer(song))
        #expect(AudioQualityClassifier.shouldSkipTranscoding(song))
        #expect(AudioQualityClassifier.classify(song) == nil)
        #expect(!AudioQualityClassifier.isSpatialOrMultichannel(song))
    }

    @Test("Missing Jellyfin channel metadata does not force a raw FLAC stream")
    func unknownStereoLayoutCanTranscode() {
        let song = DisplayableSong(id: "unknown", title: "Music", audioFormat: "flac",
                                   bitRate: nil, channelCount: nil)
        #expect(!AudioQualityClassifier.shouldSkipTranscoding(song))
    }

    @Test("Multichannel FLAC bypasses stereo cache")
    func surroundFLAC() {
        let song = DisplayableSong(id: "flac", title: "Music", audioFormat: "flac", bitDepth: 24, samplingRate: 96_000, channelCount: 6)
        #expect(AudioQualityClassifier.requiresSystemPlayer(song))
        #expect(AudioQualityClassifier.shouldBypassEphemeralCache(song))
        #expect(!AudioQualityClassifier.usesAtmosSpatialization(song))
    }

    @Test("Download extensions describe the response, not the source")
    func downloadExtensions() {
        #expect(CacheFormat.mp3_320.downloadFileExtension(mimeType: "audio/mpeg", originalSuffix: "flac") == "mp3")
        #expect(CacheFormat.opus_128.downloadFileExtension(mimeType: "audio/ogg", originalSuffix: "m4a") == "ogg")
        #expect(CacheFormat.mp3_192.downloadFileExtension(mimeType: "application/octet-stream", originalSuffix: "flac") == "mp3")
        #expect(CacheFormat.flacOriginal.downloadFileExtension(mimeType: "application/octet-stream", originalSuffix: "EAC3") == "eac3")
        #expect(CacheFormat.flacOriginal.downloadFileExtension(mimeType: nil, originalSuffix: "../../unsafe") == "bin")
    }

    @Test("MP3 is never classified as lossless even with bitDepth")
    func mp3NotLossless() {
        let song = DisplayableSong(
            id: "1",
            title: "Lossy",
            audioFormat: "MP3",
            contentType: "audio/mpeg",
            bitRate: 320,
            bitDepth: 16,
            samplingRate: 44_100
        )
        #expect(AudioQualityClassifier.classify(song) == nil)
    }

    @Test("AAC in M4A with bitDepth and lossy bitrate is not lossless")
    func aacM4ANotLossless() {
        let song = DisplayableSong(
            id: "2",
            title: "AAC",
            audioFormat: "M4A",
            contentType: "audio/mp4",
            bitRate: 256,
            bitDepth: 16,
            samplingRate: 44_100
        )
        #expect(AudioQualityClassifier.classify(song) == nil)
    }

    @Test("Explicit AAC suffix is never lossless")
    func aacSuffixNotLossless() {
        let song = DisplayableSong(
            id: "3",
            title: "AAC",
            audioFormat: "AAC",
            contentType: "audio/aac",
            bitRate: 256,
            bitDepth: 16,
            samplingRate: 44_100
        )
        #expect(AudioQualityClassifier.classify(song) == nil)
    }

    @Test("FLAC is lossless")
    func flacLossless() {
        let song = DisplayableSong(
            id: "4",
            title: "FLAC",
            audioFormat: "FLAC",
            contentType: "audio/flac",
            bitRate: 900,
            bitDepth: 16,
            samplingRate: 44_100
        )
        let kind = AudioQualityClassifier.classify(song)
        guard case .lossless(let bitDepth, let sampleRate, let format) = kind else {
            Issue.record("Expected lossless, got \(String(describing: kind))")
            return
        }
        #expect(bitDepth == 16)
        #expect(sampleRate == 44_100)
        #expect(format == "FLAC")
    }

    @Test("ALAC-looking M4A with high bitrate is lossless")
    func alacM4ALossless() {
        let song = DisplayableSong(
            id: "5",
            title: "ALAC",
            audioFormat: "M4A",
            contentType: "audio/mp4",
            bitRate: 800,
            bitDepth: 16,
            samplingRate: 44_100
        )
        let kind = AudioQualityClassifier.classify(song)
        guard case .lossless(_, _, let format) = kind else {
            Issue.record("Expected lossless, got \(String(describing: kind))")
            return
        }
        #expect(format == "ALAC")
    }
}
