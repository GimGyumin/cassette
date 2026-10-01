// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// Which gain tag to prefer when computing ReplayGain.
nonisolated enum ReplayGainMode: String, CaseIterable, Sendable, Codable {
    case track
    case album
}

/// Snapshot of ReplayGain settings that can be passed across actor boundaries.
/// Captured from ReplayGainSettings on the MainActor before crossing into another actor.
nonisolated struct ReplayGainConfig: Sendable, Equatable {
    let enabled: Bool
    let mode: ReplayGainMode
    let preAmp: Double
    let preventClipping: Bool
}

/// User-configurable ReplayGain preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services capture a ReplayGainConfig snapshot via MainActor.run.
@Observable
@MainActor
final class ReplayGainSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _enabled: Bool
    @ObservationIgnored private var _mode: ReplayGainMode
    @ObservationIgnored private var _preAmp: Double
    @ObservationIgnored private var _preventClipping: Bool

    // MARK: - Visible properties (manual observation hooks)

    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return _enabled
        }
        set {
            withMutation(keyPath: \.enabled) {
                _enabled = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
        }
    }

    var mode: ReplayGainMode {
        get {
            access(keyPath: \.mode)
            return _mode
        }
        set {
            withMutation(keyPath: \.mode) {
                _mode = newValue
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modeKey)
        }
    }

    var preAmp: Double {
        get {
            access(keyPath: \.preAmp)
            return _preAmp
        }
        set {
            let clamped = max(Self.minPreAmp, min(Self.maxPreAmp, newValue))
            withMutation(keyPath: \.preAmp) {
                _preAmp = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Self.preAmpKey)
        }
    }

    var preventClipping: Bool {
        get {
            access(keyPath: \.preventClipping)
            return _preventClipping
        }
        set {
            withMutation(keyPath: \.preventClipping) {
                _preventClipping = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.preventClippingKey)
        }
    }

    // MARK: - Defaults, bounds & keys

    nonisolated static let defaultEnabled: Bool = false
    nonisolated static let defaultMode: ReplayGainMode = .track
    nonisolated static let defaultPreAmp: Double = 0
    nonisolated static let defaultPreventClipping: Bool = true
    nonisolated static let minPreAmp: Double = -15
    nonisolated static let maxPreAmp: Double = 15

    nonisolated private static let enabledKey = "cassette.replayGain.enabled"
    nonisolated private static let modeKey = "cassette.replayGain.mode"
    nonisolated private static let preAmpKey = "cassette.replayGain.preAmp"
    nonisolated private static let preventClippingKey = "cassette.replayGain.preventClipping"

    // MARK: - Derived

    /// Captures a sendable snapshot for crossing into actor-isolated code.
    var config: ReplayGainConfig {
        ReplayGainConfig(enabled: _enabled, mode: _mode, preAmp: _preAmp, preventClipping: _preventClipping)
    }

    // MARK: - Init

    init() {
        Self.registerDefaults()
        _enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let modeRaw = UserDefaults.standard.string(forKey: Self.modeKey)
        _mode = ReplayGainMode(rawValue: modeRaw ?? "") ?? Self.defaultMode
        if let stored = Self.double(forKey: Self.preAmpKey) {
            _preAmp = max(Self.minPreAmp, min(Self.maxPreAmp, stored))
        } else {
            _preAmp = Self.defaultPreAmp
        }
        if UserDefaults.standard.object(forKey: Self.preventClippingKey) != nil {
            _preventClipping = UserDefaults.standard.bool(forKey: Self.preventClippingKey)
        } else {
            _preventClipping = Self.defaultPreventClipping
        }
    }

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "cassette.replayGain.enabled": false,
            "cassette.replayGain.mode": ReplayGainMode.track.rawValue,
            "cassette.replayGain.preAmp": 0.0,
            "cassette.replayGain.preventClipping": true,
        ])
    }

    /// Re-read UserDefaults after the in-app Settings screen wrote new values.
    func reloadFromDefaults() {
        withMutation(keyPath: \.enabled) {
            withMutation(keyPath: \.mode) {
                withMutation(keyPath: \.preAmp) {
                    withMutation(keyPath: \.preventClipping) {
                        applyFromDefaults()
                    }
                }
            }
        }
    }

    private func applyFromDefaults() {
        _enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        let modeRaw = UserDefaults.standard.string(forKey: Self.modeKey)
        _mode = ReplayGainMode(rawValue: modeRaw ?? "") ?? Self.defaultMode

        if UserDefaults.standard.object(forKey: Self.preAmpKey) != nil {
            let stored = Self.double(forKey: Self.preAmpKey) ?? Self.defaultPreAmp
            _preAmp = max(Self.minPreAmp, min(Self.maxPreAmp, stored))
        } else {
            _preAmp = Self.defaultPreAmp
        }

        if UserDefaults.standard.object(forKey: Self.preventClippingKey) != nil {
            _preventClipping = UserDefaults.standard.bool(forKey: Self.preventClippingKey)
        } else {
            _preventClipping = Self.defaultPreventClipping
        }
    }

    /// Stored doubles may persist as String or NSNumber depending on the writer.
    private nonisolated static func double(forKey key: String) -> Double? {
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
