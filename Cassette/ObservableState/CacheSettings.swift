// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// User-configurable cache preferences persisted in UserDefaults.
/// @Observable so SettingsView updates live when the user changes settings.
/// Injected into AppContainer; services read values via MainActor.run when needed.
@Observable
@MainActor
final class CacheSettings {
    // MARK: - Storage (observation ignored)

    @ObservationIgnored private var _maxCacheMegabytes: Int
    @ObservationIgnored private var _cacheFormat: CacheFormat
    @ObservationIgnored private var _cacheOverCellular: Bool

    // MARK: - Visible properties (manual observation hooks)

    var maxCacheMegabytes: Int {
        get {
            access(keyPath: \.maxCacheMegabytes)
            return _maxCacheMegabytes
        }
        set {
            let resolved = Self.storageOptionsMB.min(by: {
                abs($0 - newValue) < abs($1 - newValue)
            }) ?? Self.defaultMaxCacheMegabytes
            withMutation(keyPath: \.maxCacheMegabytes) {
                _maxCacheMegabytes = resolved
            }
            UserDefaults.standard.set(resolved, forKey: Self.maxCacheMegabytesKey)
        }
    }

    var maxCacheBytes: Int64 { Int64(maxCacheMegabytes) * 1_024 * 1_024 }

    var cacheFormat: CacheFormat {
        get {
            access(keyPath: \.cacheFormat)
            return _cacheFormat
        }
        set {
            withMutation(keyPath: \.cacheFormat) {
                _cacheFormat = newValue
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.cacheFormatKey)
        }
    }

    var cacheOverCellular: Bool {
        get {
            access(keyPath: \.cacheOverCellular)
            return _cacheOverCellular
        }
        set {
            withMutation(keyPath: \.cacheOverCellular) {
                _cacheOverCellular = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.cacheOverCellularKey)
        }
    }

    // MARK: - Defaults & keys

    static let storageOptionsMB = [512, 1_024, 2_048, 4_096, 8_192, 16_384]
    static let defaultMaxCacheMegabytes = 2_048
    static let defaultFormat: CacheFormat = .matchStream
    static let defaultCacheOverCellular: Bool = false

    private static let maxCacheMegabytesKey = "cassette.cache.maxMegabytes"
    private static let cacheFormatKey = "cassette.cache.format"
    private static let cacheOverCellularKey = "cassette.cache.cellular"

    // MARK: - Init

    init() {
        CacheFormat.migrateLegacyStoredValues()
        let loaded = UserDefaults.standard.integer(forKey: Self.maxCacheMegabytesKey)
        self._maxCacheMegabytes = Self.storageOptionsMB.contains(loaded)
            ? loaded : Self.defaultMaxCacheMegabytes

        let loadedFormatRaw = UserDefaults.standard.string(forKey: Self.cacheFormatKey)
        self._cacheFormat = CacheFormat(rawValue: loadedFormatRaw ?? "") ?? Self.defaultFormat

        self._cacheOverCellular = UserDefaults.standard.bool(forKey: Self.cacheOverCellularKey)
    }

    func reloadFromDefaults() {
        CacheFormat.migrateLegacyStoredValues()
        let loaded = UserDefaults.standard.integer(forKey: Self.maxCacheMegabytesKey)
        _maxCacheMegabytes = Self.storageOptionsMB.contains(loaded)
            ? loaded : Self.defaultMaxCacheMegabytes
        let loadedFormatRaw = UserDefaults.standard.string(forKey: Self.cacheFormatKey)
        _cacheFormat = CacheFormat(rawValue: loadedFormatRaw ?? "") ?? Self.defaultFormat
        _cacheOverCellular = UserDefaults.standard.bool(forKey: Self.cacheOverCellularKey)
    }
}
