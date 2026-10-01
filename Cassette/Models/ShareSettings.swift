// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

// MARK: - ShareExpiration

enum ShareExpiration: String, CaseIterable, Sendable {
    case oneDay
    case sevenDays
    case thirtyDays
    case oneYear
    case never

    var title: String {
        switch self {
        case .oneDay: String(localized: "1 Day", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share expiration: 1 day")
        case .sevenDays: String(localized: "7 Days", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share expiration: 7 days")
        case .thirtyDays: String(localized: "30 Days", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share expiration: 30 days")
        case .oneYear: String(localized: "1 Year", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share expiration: 1 year")
        case .never: String(localized: "Never", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share expiration: never")
        }
    }

    var date: Date? {
        switch self {
        case .oneDay: Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .sevenDays: Calendar.current.date(byAdding: .day, value: 7, to: Date())
        case .thirtyDays: Calendar.current.date(byAdding: .day, value: 30, to: Date())
        case .oneYear: Calendar.current.date(byAdding: .year, value: 1, to: Date())
        case .never: nil
        }
    }
}

// MARK: - ShareDescriptionMode

enum ShareDescriptionMode: String, CaseIterable, Sendable {
    case trackTitle
    case albumTitle
    case custom

    var title: String {
        switch self {
        case .trackTitle: String(localized: "Track Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share description mode: track title")
        case .albumTitle: String(localized: "Album Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share description mode: album title")
        case .custom: String(localized: "Custom", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share description mode: custom")
        }
    }
}

// MARK: - ShareSettings

/// User-configurable Navidrome share preferences persisted in UserDefaults.
/// `@Observable` so SettingsView updates live when the user changes settings.
@Observable
final class ShareSettings {
    static let shared = ShareSettings()

    private enum Key {
        static let allowDownloads = "NavidromeShare.allowDownloads"
        static let originalFormat = "NavidromeShare.originalFormat"
        static let expiration = "NavidromeShare.expiration"
        static let descriptionMode = "NavidromeShare.descriptionMode"
    }

    var allowDownloads: Bool {
        didSet {
            UserDefaults.standard.set(allowDownloads, forKey: Key.allowDownloads)
        }
    }

    var shareOriginalFormat: Bool {
        didSet {
            UserDefaults.standard.set(shareOriginalFormat, forKey: Key.originalFormat)
        }
    }

    var expiration: ShareExpiration {
        didSet {
            UserDefaults.standard.set(expiration.rawValue, forKey: Key.expiration)
        }
    }

    var descriptionMode: ShareDescriptionMode {
        didSet {
            UserDefaults.standard.set(descriptionMode.rawValue, forKey: Key.descriptionMode)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        Self.registerDefaults()

        self.allowDownloads = defaults.bool(forKey: Key.allowDownloads)
        self.shareOriginalFormat = defaults.bool(forKey: Key.originalFormat)

        if let expRaw = defaults.string(forKey: Key.expiration),
           let exp = ShareExpiration(rawValue: expRaw) {
            self.expiration = exp
        } else {
            self.expiration = .oneYear
        }

        if let descRaw = defaults.string(forKey: Key.descriptionMode),
           let desc = ShareDescriptionMode(rawValue: descRaw) {
            self.descriptionMode = desc
        } else {
            self.descriptionMode = .trackTitle
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        let allow = defaults.bool(forKey: Key.allowDownloads)
        if allowDownloads != allow { allowDownloads = allow }

        let original = defaults.bool(forKey: Key.originalFormat)
        if shareOriginalFormat != original { shareOriginalFormat = original }

        let expirationRaw = defaults.string(forKey: Key.expiration)
        let expirationValue = expirationRaw.flatMap(ShareExpiration.init(rawValue:)) ?? .oneYear
        if expiration != expirationValue { expiration = expirationValue }

        let descriptionRaw = defaults.string(forKey: Key.descriptionMode)
        let descriptionValue = descriptionRaw.flatMap(ShareDescriptionMode.init(rawValue:)) ?? .trackTitle
        if descriptionMode != descriptionValue { descriptionMode = descriptionValue }
    }

    /// Registers default values so that first-launch reads return sensible defaults.
    static func registerDefaults() {
        let defaults: [String: Any] = [
            Key.allowDownloads: false,
            Key.originalFormat: false,
            Key.expiration: ShareExpiration.oneYear.rawValue,
            Key.descriptionMode: ShareDescriptionMode.trackTitle.rawValue,
        ]
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Builds a `ShareOptions` value from the current settings, resolving the
    /// description for the given track title and album title context.
    func makeOptions(trackTitle: String, albumTitle: String? = nil) -> ShareOptions {
        let description: String?
        switch descriptionMode {
        case .trackTitle:
            description = trackTitle.isEmpty ? nil : trackTitle
        case .albumTitle:
            description = albumTitle?.isEmpty == false ? albumTitle : trackTitle
        case .custom:
            description = nil
        }
        return ShareOptions(
            description: description,
            allowDownloads: allowDownloads,
            shareOriginal: shareOriginalFormat,
            expires: expiration.date
        )
    }

    /// Builds a `ShareOptions` value for an album share.
    func makeAlbumOptions(albumName: String) -> ShareOptions {
        let description: String?
        switch descriptionMode {
        case .albumTitle:
            description = albumName.isEmpty ? nil : albumName
        case .trackTitle:
            description = albumName.isEmpty ? nil : albumName
        case .custom:
            description = nil
        }
        return ShareOptions(
            description: description,
            allowDownloads: allowDownloads,
            shareOriginal: shareOriginalFormat,
            expires: expiration.date
        )
    }
}