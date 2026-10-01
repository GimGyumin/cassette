// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Combine

/// Catalog source for ISRC lookup (Music Haptics). MusicBrainz remains a free fallback.
enum ISRCProvider: String, CaseIterable, Identifiable {
    case spotify = "spotify"
    case appleMusic = "appleMusic"

    var id: String { rawValue }
}

/// User preferences for catalog enrichment (Wikipedia / MusicBrainz), Spotify ISRC lookup, and related features.
@MainActor
final class AppleMusicSettings: ObservableObject {
    static let shared = AppleMusicSettings()

    private let defaults = UserDefaults.standard

    /// When enabled, album/artist About text is enriched from Wikipedia / MusicBrainz.
    @Published var enrichMetadata: Bool {
        didSet { defaults.set(enrichMetadata, forKey: Self.enrichKey) }
    }

    @Published var musicHapticsEnabled: Bool {
        didSet { defaults.set(musicHapticsEnabled, forKey: Self.hapticsKey) }
    }

    @Published var musicHapticsIntensity: Double {
        didSet { defaults.set(musicHapticsIntensity, forKey: Self.hapticsIntensityKey) }
    }

    /// Preferred commercial catalog for ISRC after MusicBrainz (Settings → ISRC provider).
    @Published var isrcProvider: ISRCProvider {
        didSet { defaults.set(isrcProvider.rawValue, forKey: Self.isrcProviderKey) }
    }

    /// Spotify Web API Client ID (Client Credentials flow) for ISRC lookup.
    @Published var spotifyClientId: String {
        didSet {
            let trimmed = spotifyClientId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != spotifyClientId {
                spotifyClientId = trimmed
                return
            }
            defaults.set(trimmed, forKey: Self.spotifyClientIdKey)
            notifySpotifyCredentialsChanged()
        }
    }

    /// Spotify Web API Client Secret (Client Credentials flow) for ISRC lookup.
    @Published var spotifyClientSecret: String {
        didSet {
            let trimmed = spotifyClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != spotifyClientSecret {
                spotifyClientSecret = trimmed
                return
            }
            SensitiveSettingsStore.set(trimmed, forKey: Self.spotifyClientSecretKey)
            notifySpotifyCredentialsChanged()
        }
    }

    /// Apple Music Media API developer token (JWT) for catalog ISRC lookup.
    @Published var appleMusicDeveloperToken: String {
        didSet {
            let sanitized = MusicKitDeveloperTokenInfo.sanitize(appleMusicDeveloperToken)
            if sanitized != appleMusicDeveloperToken {
                appleMusicDeveloperToken = sanitized
                return
            }
            let previous = SensitiveSettingsStore.string(forKey: Self.appleMusicDeveloperTokenKey) ?? ""
            SensitiveSettingsStore.set(sanitized, forKey: Self.appleMusicDeveloperTokenKey)
            if sanitized != previous {
                if sanitized.isEmpty {
                    defaults.removeObject(forKey: Self.appleMusicDeveloperTokenUpdatedAtKey)
                } else {
                    defaults.set(Date().timeIntervalSince1970, forKey: Self.appleMusicDeveloperTokenUpdatedAtKey)
                }
                objectWillChange.send()
            }
            notifyAppleMusicCredentialsChanged()
        }
    }

    /// Optional Apple Music storefront (`kr`, `us`, …). Empty → device region.
    @Published var appleMusicStorefront: String {
        didSet {
            let trimmed = appleMusicStorefront.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed != appleMusicStorefront {
                appleMusicStorefront = trimmed
                return
            }
            defaults.set(trimmed, forKey: Self.appleMusicStorefrontKey)
            notifyAppleMusicCredentialsChanged()
        }
    }

    /// When the developer token was last pasted in Settings (device clock).
    var appleMusicDeveloperTokenUpdatedAt: Date? {
        let raw = defaults.object(forKey: Self.appleMusicDeveloperTokenUpdatedAtKey)
        if let interval = raw as? TimeInterval {
            return Date(timeIntervalSince1970: interval)
        }
        if let date = raw as? Date {
            return date
        }
        return nil
    }

    /// Claims from the current JWT (`iat` / `exp`), if parseable.
    var appleMusicDeveloperTokenClaims: MusicKitDeveloperTokenInfo.Claims? {
        MusicKitDeveloperTokenInfo.parse(appleMusicDeveloperToken)
    }

    nonisolated static let enrichKey = "cassette.appleMusic.enrichMetadata"
    nonisolated static let hapticsKey = "cassette.haptics.withMusic"
    nonisolated static let hapticsIntensityKey = "cassette.haptics.intensity"
    nonisolated static let isrcProviderKey = "cassette.isrc.provider"
    nonisolated static let spotifyClientIdKey = "cassette.spotify.clientId"
    nonisolated static let spotifyClientSecretKey = "cassette.spotify.clientSecret"
    nonisolated static let appleMusicDeveloperTokenKey = "cassette.appleMusic.developerToken"
    nonisolated static let appleMusicStorefrontKey = "cassette.appleMusic.storefront"
    nonisolated static let appleMusicDeveloperTokenUpdatedAtKey = "cassette.appleMusic.developerTokenUpdatedAt"

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "cassette.appleMusic.enrichMetadata": true,
            // Off by default — probing ISRC haptics hits a sandboxed system XPC service.
            "cassette.haptics.withMusic": false,
            "cassette.haptics.intensity": 0.55,
            "cassette.isrc.provider": ISRCProvider.spotify.rawValue,
            "cassette.spotify.clientId": "",
            "cassette.appleMusic.storefront": "",
        ])
    }

    private init() {
        Self.registerDefaults()
        enrichMetadata = defaults.object(forKey: Self.enrichKey) as? Bool ?? true
        musicHapticsEnabled = defaults.bool(forKey: Self.hapticsKey)
        musicHapticsIntensity = defaults.object(forKey: Self.hapticsIntensityKey) as? Double ?? 0.55
        if let raw = defaults.string(forKey: Self.isrcProviderKey),
           let provider = ISRCProvider(rawValue: raw) {
            isrcProvider = provider
        } else {
            isrcProvider = .spotify
        }
        spotifyClientId = defaults.string(forKey: Self.spotifyClientIdKey) ?? ""
        spotifyClientSecret = SensitiveSettingsStore.migratedString(
            forKey: Self.spotifyClientSecretKey,
            defaults: defaults
        )
        appleMusicDeveloperToken = MusicKitDeveloperTokenInfo.sanitize(
            SensitiveSettingsStore.migratedString(
                forKey: Self.appleMusicDeveloperTokenKey,
                defaults: defaults
            )
        )
        appleMusicStorefront = defaults.string(forKey: Self.appleMusicStorefrontKey) ?? ""
        // Seed "last updated" from JWT iat when the token predated this feature.
        if !appleMusicDeveloperToken.isEmpty,
           defaults.object(forKey: Self.appleMusicDeveloperTokenUpdatedAtKey) == nil,
           let iat = MusicKitDeveloperTokenInfo.parse(appleMusicDeveloperToken)?.issuedAt {
            defaults.set(iat.timeIntervalSince1970, forKey: Self.appleMusicDeveloperTokenUpdatedAtKey)
        }

        let id = spotifyClientId
        let secret = spotifyClientSecret
        let token = appleMusicDeveloperToken
        let storefront = appleMusicStorefront
        Task {
            await SpotifyCatalogService.shared.setCredentials(clientId: id, clientSecret: secret)
            await AppleMusicCatalogService.shared.setCredentials(developerToken: token, storefront: storefront)
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    /// Re-read values written by Settings.app when the app becomes active again.
    /// Defaults notifications may be coalesced while the process is suspended.
    func reloadFromDefaults() {
        let enrich = defaults.object(forKey: Self.enrichKey) as? Bool ?? true
        if enrichMetadata != enrich { enrichMetadata = enrich }
        let haptics = defaults.bool(forKey: Self.hapticsKey)
        if musicHapticsEnabled != haptics { musicHapticsEnabled = haptics }
        let intensity = defaults.object(forKey: Self.hapticsIntensityKey) as? Double ?? 0.55
        if musicHapticsIntensity != intensity { musicHapticsIntensity = intensity }
        if let raw = defaults.string(forKey: Self.isrcProviderKey),
           let provider = ISRCProvider(rawValue: raw),
           isrcProvider != provider {
            isrcProvider = provider
        }
        let id = defaults.string(forKey: Self.spotifyClientIdKey) ?? ""
        if spotifyClientId != id { spotifyClientId = id }
        let storefront = defaults.string(forKey: Self.appleMusicStorefrontKey) ?? ""
        if appleMusicStorefront != storefront { appleMusicStorefront = storefront }
    }

    var hasSpotifyCredentials: Bool {
        !spotifyClientId.isEmpty && !spotifyClientSecret.isEmpty
    }

    var hasAppleMusicDeveloperToken: Bool {
        !appleMusicDeveloperToken.isEmpty
    }

    private func notifySpotifyCredentialsChanged() {
        NotificationCenter.default.post(name: .cassetteSpotifyCredentialsChanged, object: nil)
        let id = spotifyClientId
        let secret = spotifyClientSecret
        Task {
            await SpotifyCatalogService.shared.setCredentials(clientId: id, clientSecret: secret)
        }
    }

    private func notifyAppleMusicCredentialsChanged() {
        let token = appleMusicDeveloperToken
        let storefront = appleMusicStorefront
        Task {
            await AppleMusicCatalogService.shared.setCredentials(developerToken: token, storefront: storefront)
        }
    }
}

extension Notification.Name {
    nonisolated static let cassetteSpotifyCredentialsChanged = Notification.Name("cassetteSpotifyCredentialsChanged")
}
