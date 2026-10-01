import Foundation
import Testing
@testable import Cassette

@Suite("CacheFormat")
struct CacheFormatTests {
    @Test("Selectable options follow Apple Music's quality order")
    func selectableOrder() {
        #expect(CacheFormat.selectableCases == [.matchStream, .flacOriginal, .aac256, .aac128, .opus_128])
        #expect(!CacheFormat.selectableCases.contains(.mp3_320))
        #expect(!CacheFormat.selectableCases.contains(.mp3_192))
        // Retired cases stay decodable so an old stored selection never fails to load.
        #expect(CacheFormat(rawValue: "mp3_320") == .mp3_320)
        #expect(CacheFormat(rawValue: "mp3_192") == .mp3_192)
        #expect(CacheFormat.allCases.count == CacheFormat.selectableCases.count + 2)
    }

    @Test("Every selectable option can be rendered as a Settings row")
    func selectableRowsArePresentable() {
        for format in CacheFormat.selectableCases {
            #expect(!format.title.isEmpty)
            #expect(format.choiceTitle == format.title)
            #expect(format.choiceSubtitle == format.subtitle)
        }
    }

    @Test("Stream requests map onto Subsonic format and maxBitRate")
    func subsonicMapping() {
        #expect(CacheFormat.matchStream.subsonicFormat == nil)
        #expect(CacheFormat.matchStream.subsonicMaxBitRate == nil)
        #expect(CacheFormat.flacOriginal.subsonicFormat == "raw")
        #expect(CacheFormat.flacOriginal.subsonicMaxBitRate == nil)
        #expect(CacheFormat.aac256.subsonicFormat == "aac")
        #expect(CacheFormat.aac256.subsonicMaxBitRate == 256)
        #expect(CacheFormat.aac128.subsonicFormat == "aac")
        #expect(CacheFormat.aac128.subsonicMaxBitRate == 128)
        #expect(CacheFormat.opus_128.subsonicFormat == "opus")
        #expect(CacheFormat.opus_128.subsonicMaxBitRate == 128)
    }

    @Test("AAC 128 kbps is a distinct stored option")
    func aac128RoundTrips() {
        #expect(CacheFormat(rawValue: "aac128") == .aac128)
        #expect(CacheFormat.aac128.title == "AAC 128 kbps")
        #expect(CacheFormat.aac256.title == "AAC 256 kbps")
        #expect(CacheFormat.aac256.subtitle != nil)
        #expect(CacheFormat.aac128.subtitle != nil)
    }

    @Test("Retired MP3 selections map onto their AAC equivalent")
    func legacyMapping() {
        #expect(CacheFormat.migratedRawValue(CacheFormat.mp3_320.rawValue) == CacheFormat.aac256.rawValue)
        #expect(CacheFormat.migratedRawValue(CacheFormat.mp3_192.rawValue) == CacheFormat.aac128.rawValue)
        for raw in ["matchStream", "flacOriginal", "aac256", "aac128", "opus_128", "", "not-a-format", "MP3_320"] {
            #expect(CacheFormat.migratedRawValue(raw) == nil)
        }
    }

    @Test("Migration never leaves a retired value behind and invents nothing")
    func migrationIsStable() {
        // A UUID-suffixed suite name: sandboxed test hosts do not always give a
        // scratch suite its own domain, so the contract is asserted rather than a
        // specific starting state.
        let suiteName = "cassette.tests.cacheFormat.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create scratch UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = CacheFormat.storedValueKeys.map { defaults.string(forKey: $0) }
        CacheFormat.migrateLegacyStoredValues(in: defaults)
        let after = CacheFormat.storedValueKeys.map { defaults.string(forKey: $0) }

        // 1. No retired raw value survives the migration.
        for value in after.compactMap({ $0 }) {
            #expect(CacheFormat.migratedRawValue(value) == nil)
            #expect(CacheFormat(rawValue: value) != .mp3_320)
            #expect(CacheFormat(rawValue: value) != .mp3_192)
        }
        // 2. Current or unknown values are untouched.
        let hadRetiredValue = before.compactMap { $0 }.contains { CacheFormat.migratedRawValue($0) != nil }
        if !hadRetiredValue {
            #expect(after == before)
        }
    }
}
