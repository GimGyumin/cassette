// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// Sendable snapshot of the gapless preference for crossing actor boundaries.
/// Captured from `GaplessSettings` on the MainActor before entering `PlayerService`.
nonisolated struct GaplessConfig: Sendable, Equatable {
    let isEnabled: Bool

    static let `default` = GaplessConfig(isEnabled: true)
}

/// User-configurable gapless playback preference persisted in UserDefaults.
///
/// `@Observable` so the Settings screen updates live when the value changes; services capture a
/// `GaplessConfig` snapshot through `MainActor.run`.
@Observable
@MainActor
final class GaplessSettings {
    @ObservationIgnored private var _isEnabled: Bool

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return _isEnabled
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                _isEnabled = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
        }
    }

    // MARK: - Defaults & keys

    /// On by default: the silence between two tracks is an artifact of CD-era players, not a
    /// feature. Users who want a hard cut can turn it off.
    nonisolated static let defaultEnabled = true
    nonisolated static let enabledKey = "cassette.gapless.enabled"

    var config: GaplessConfig {
        GaplessConfig(isEnabled: _isEnabled)
    }

    // MARK: - Init

    init() {
        Self.registerDefaults()
        _isEnabled = Self.storedEnabled()
    }

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: defaultEnabled])
    }

    /// Re-read UserDefaults after the in-app Settings screen wrote new values.
    func reloadFromDefaults() {
        withMutation(keyPath: \.isEnabled) {
            _isEnabled = Self.storedEnabled()
        }
    }

    private nonisolated static func storedEnabled() -> Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}
