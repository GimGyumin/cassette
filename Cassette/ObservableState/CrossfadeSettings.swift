// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// Sendable snapshot of crossfade settings for crossing actor boundaries.
/// Captured from CrossfadeSettings on the MainActor before passing into PlayerService.
nonisolated struct CrossfadeConfig: Sendable, Equatable {
    let duration: Double
    let disableForGapless: Bool
}

/// User-configurable crossfade preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services capture a CrossfadeConfig snapshot via MainActor.run.
@Observable
@MainActor
final class CrossfadeSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _duration: Double
    @ObservationIgnored private var _disableForGapless: Bool

    // MARK: - Visible properties (manual observation hooks)

    var duration: Double {
        get {
            access(keyPath: \.duration)
            return _duration
        }
        set {
            let clamped = max(Self.minDuration, min(Self.maxDuration, newValue))
            withMutation(keyPath: \.duration) {
                _duration = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Self.durationKey)
        }
    }

    var disableForGapless: Bool {
        get {
            access(keyPath: \.disableForGapless)
            return _disableForGapless
        }
        set {
            withMutation(keyPath: \.disableForGapless) {
                _disableForGapless = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.disableForGaplessKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    nonisolated static let defaultDuration: Double = 0
    nonisolated static let minDuration: Double = 0
    nonisolated static let maxDuration: Double = 12

    nonisolated private static let durationKey = "cassette.crossfade.duration"
    nonisolated private static let disableForGaplessKey = "cassette.crossfade.disableForGapless"

    // MARK: - Derived

    /// Captures a sendable snapshot for crossing into actor-isolated code.
    var config: CrossfadeConfig {
        CrossfadeConfig(duration: _duration, disableForGapless: _disableForGapless)
    }

    // MARK: - Init

    init() {
        Self.registerDefaults()
        if let stored = Self.double(forKey: Self.durationKey) {
            _duration = max(Self.minDuration, min(Self.maxDuration, stored))
        } else {
            _duration = Self.defaultDuration
        }
        if UserDefaults.standard.object(forKey: Self.disableForGaplessKey) != nil {
            _disableForGapless = UserDefaults.standard.bool(forKey: Self.disableForGaplessKey)
        } else {
            _disableForGapless = true
        }
    }

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "cassette.crossfade.duration": 0.0,
            "cassette.crossfade.disableForGapless": true,
        ])
    }

    /// Re-read UserDefaults after the in-app Settings screen wrote new values.
    func reloadFromDefaults() {
        withMutation(keyPath: \.duration) {
            withMutation(keyPath: \.disableForGapless) {
                applyFromDefaults()
            }
        }
    }

    private func applyFromDefaults() {
        if UserDefaults.standard.object(forKey: Self.durationKey) != nil {
            let stored = Self.double(forKey: Self.durationKey) ?? Self.defaultDuration
            _duration = max(Self.minDuration, min(Self.maxDuration, stored))
        } else {
            _duration = Self.defaultDuration
        }
        // Default true: gapless albums should not be interrupted by a crossfade.
        if UserDefaults.standard.object(forKey: Self.disableForGaplessKey) != nil {
            _disableForGapless = UserDefaults.standard.bool(forKey: Self.disableForGaplessKey)
        } else {
            _disableForGapless = true
        }
    }

    /// Stored doubles may persist as String or NSNumber depending on the writer.
    private static func double(forKey key: String) -> Double? {
        let object = UserDefaults.standard.object(forKey: key)
        if let number = object as? NSNumber {
            return number.doubleValue
        }
        if let string = object as? String, let value = Double(string) {
            return value
        }
        return nil
    }
}
