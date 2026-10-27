// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

@Suite("Lossless settings")
@MainActor
struct LosslessSettingsTests {
    @Test func masterSwitchPreservesChoicesAcrossRelaunch() throws {
        let suite = "LosslessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StreamingSettings(defaults: defaults)
        #expect(settings.losslessAudioEnabled)
        settings.wifiFormat = .flacOriginal
        settings.cellularFormat = .aac128
        settings.downloadFormat = .matchStream
        settings.losslessAudioEnabled = false
        #expect(settings.formatForCurrentNetwork(isLimited: false) == .aac256)
        #expect(settings.formatForCurrentNetwork(isLimited: true) == .aac128)
        #expect(settings.effectiveDownloadFormat == .aac256)
        #expect(!settings.allowsWiFiLosslessUpgrade)

        let restored = StreamingSettings(defaults: defaults)
        #expect(!restored.losslessAudioEnabled)
        #expect(restored.wifiFormat == .flacOriginal)
        #expect(restored.cellularFormat == .aac128)
        #expect(restored.downloadFormat == .matchStream)
        restored.losslessAudioEnabled = true
        #expect(restored.formatForCurrentNetwork(isLimited: false) == .flacOriginal)
        #expect(restored.formatForCurrentNetwork(isLimited: true) == .aac128)
        #expect(restored.effectiveDownloadFormat == .matchStream)
        #expect(restored.allowsWiFiLosslessUpgrade)
    }

    @Test func disabledLosslessNeverRaisesAnExplicitLossyQuality() {
        for format in [CacheFormat.aac256, .aac128, .opus_128] {
            #expect(StreamingSettings.effectiveFormat(format, losslessEnabled: false) == format)
        }
        for format in [CacheFormat.matchStream, .flacOriginal] {
            #expect(StreamingSettings.effectiveFormat(format, losslessEnabled: false) == .aac256)
            #expect(StreamingSettings.effectiveFormat(format, losslessEnabled: true) == format)
        }
    }

    @Test func resettingPreferenceRestoresDefaultWithoutOverwritingFormats() throws {
        let suite = "LosslessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = StreamingSettings(defaults: defaults)
        settings.wifiFormat = .flacOriginal
        settings.losslessAudioEnabled = false
        defaults.removeObject(forKey: StreamingSettings.losslessAudioKey)
        settings.reloadFromDefaults()
        #expect(settings.losslessAudioEnabled)
        #expect(settings.formatForCurrentNetwork(isLimited: false) == .flacOriginal)
    }
}
