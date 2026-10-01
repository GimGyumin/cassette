// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// User-configurable format for cached tracks. Exposed in Settings (phase 5).
/// `.matchStream` caches the same format the server serves for streaming.
/// Other cases force a specific transcode via Subsonic `format` + `maxBitRate` params.
nonisolated enum CacheFormat: String, CaseIterable, Identifiable, Sendable {
    case matchStream
    case flacOriginal
    case aac256
    case aac128
    case opus_128
    /// Legacy MP3 transcodes. Kept so stored selections still decode; they are
    /// migrated to their AAC equivalent on launch and are no longer offered.
    case mp3_320
    case mp3_192

    var id: String { rawValue }

    /// Quality options offered in Settings, in Apple Music's order
    /// (Automatic → Lossless → high → low → data saver).
    static var selectableCases: [CacheFormat] {
        [.matchStream, .flacOriginal, .aac256, .aac128, .opus_128]
    }

    /// Row title used throughout Settings.
    var title: String {
        switch self {
        case .matchStream:  return String(localized: "Automatic", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .flacOriginal: return String(localized: "Lossless", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .aac256:       return "AAC 256 kbps"
        case .aac128:       return "AAC 128 kbps"
        case .opus_128:     return String(localized: "Data Saver", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .mp3_320:      return "MP3 320 kbps"
        case .mp3_192:      return "MP3 192 kbps"
        }
    }

    /// Secondary line under the row title, mirroring Apple Music's quality rows.
    var subtitle: String? {
        switch self {
        case .matchStream:  return String(localized: "Uses your server's default setting", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .flacOriginal: return String(localized: "Original file without conversion", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .aac256:       return String(localized: "High quality AAC", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .aac128:       return String(localized: "Smaller files, good quality", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .opus_128:     return "Opus 128 kbps"
        case .mp3_320, .mp3_192: return nil
        }
    }

    /// Legacy alias used by pickers that still show a single-line label.
    var displayName: String { title }

    /// Subsonic `format` query param. `nil` = no format override (server default).
    var subsonicFormat: String? {
        switch self {
        case .matchStream:  return nil
        case .flacOriginal: return "raw"  // Subsonic "raw" = no transcoding, serve original file
        case .aac256, .aac128: return "aac"
        case .mp3_320, .mp3_192: return "mp3"
        case .opus_128:     return "opus"
        }
    }

    /// Subsonic `maxBitRate` query param (kbps). `nil` = no bitrate constraint.
    var subsonicMaxBitRate: Int? {
        switch self {
        case .matchStream, .flacOriginal: return nil
        case .aac256:                     return 256
        case .aac128:                     return 128
        case .mp3_320:                    return 320
        case .mp3_192:                    return 192
        case .opus_128:                   return 128
        }
    }

    func downloadFileExtension(mimeType: String?, originalSuffix: String?) -> String {
        switch mimeType?.lowercased().split(separator: ";").first.map(String.init) {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/opus": return "opus"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        default:
            if let format = subsonicFormat, format != "raw" { return format }
            let suffix = originalSuffix?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? ""
            return !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) ? suffix : "bin"
        }
    }
}

// MARK: - Settings presentation

extension CacheFormat: SettingsChoiceItem {
    var choiceTitle: String { title }
    var choiceSubtitle: String? { subtitle }
}

// MARK: - Legacy migration

extension CacheFormat {
    /// UserDefaults keys that store a `CacheFormat` raw value.
    static let storedValueKeys = [
        "cassette.streaming.wifi",
        "cassette.streaming.cellular",
        "cassette.streaming.download",
        "cassette.cache.format",
    ]

    /// Retired raw values map onto their AAC equivalent. `nil` means "leave as is".
    ///
    /// Kept as a pure function so the mapping can be unit-tested without touching
    /// `UserDefaults` (sandboxed test hosts do not guarantee an isolated scratch suite).
    static func migratedRawValue(_ raw: String) -> String? {
        switch raw {
        case mp3_320.rawValue: return aac256.rawValue
        case mp3_192.rawValue: return aac128.rawValue
        default: return nil
        }
    }

    /// Retired options are mapped onto their AAC equivalent once, so a stored
    /// MP3 selection never falls back to a default or becomes unselectable.
    static func migrateLegacyStoredValues(in defaults: UserDefaults = .standard) {
        for key in storedValueKeys {
            guard let raw = defaults.string(forKey: key),
                  let replacement = migratedRawValue(raw) else { continue }
            defaults.set(replacement, forKey: key)
        }
    }
}

