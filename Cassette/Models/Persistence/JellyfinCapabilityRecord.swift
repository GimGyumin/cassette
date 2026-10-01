// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import SwiftData

enum JellyfinFeature: String, Codable, CaseIterable, Sendable {
    case quickConnect, lanDiscovery, playbackInfo, hls
    case playlistManagement, playlistArtwork, playlistFavorite
    case multiLibrary, instantMix, sonicSimilarity, lyrics, transcoding
    case browsing, search, sortingAndFiltering, rating, directPlay, originalFile
    case replayGain, playbackReporting, scrobbling, wordTimedLyrics
}

enum JellyfinFeatureSupport: Int, Codable, Sendable {
    case unknown = 0
    case supported = 1
    case unsupported = 2
}

nonisolated struct JellyfinCapabilitySnapshot: Sendable, Equatable {
    let serverID: UUID
    let isAvailable: Bool
    let serverVersion: String?
    let serverName: String?
    let checkedAt: Date
    let featureSupport: [JellyfinFeature: JellyfinFeatureSupport]

    func support(for feature: JellyfinFeature) -> JellyfinFeatureSupport {
        featureSupport[feature] ?? .unknown
    }
}

/// Server-scoped, expiring capability cache. Features remain unknown until their actual
/// endpoint succeeds or returns a definitive unsupported response.
@Model
final class JellyfinCapabilityRecord {
    @Attribute(.unique) var serverID: UUID
    var isAvailable: Bool
    var serverVersion: String?
    var serverName: String?
    var checkedAt: Date
    var featureSupportData: Data?

    init(
        serverID: UUID,
        isAvailable: Bool,
        serverVersion: String? = nil,
        serverName: String? = nil,
        checkedAt: Date = Date(),
        featureSupport: [JellyfinFeature: JellyfinFeatureSupport] = [:]
    ) {
        self.serverID = serverID
        self.isAvailable = isAvailable
        self.serverVersion = serverVersion
        self.serverName = serverName
        self.checkedAt = checkedAt
        self.featureSupportData = Self.encode(featureSupport)
    }

    var featureSupport: [JellyfinFeature: JellyfinFeatureSupport] {
        get { Self.decode(featureSupportData) }
        set { featureSupportData = Self.encode(newValue) }
    }

    var snapshot: JellyfinCapabilitySnapshot {
        JellyfinCapabilitySnapshot(
            serverID: serverID,
            isAvailable: isAvailable,
            serverVersion: serverVersion,
            serverName: serverName,
            checkedAt: checkedAt,
            featureSupport: featureSupport
        )
    }

    private static func encode(_ value: [JellyfinFeature: JellyfinFeatureSupport]) -> Data? {
        let raw = Dictionary(uniqueKeysWithValues: value.map { ($0.key.rawValue, $0.value.rawValue) })
        return try? JSONEncoder().encode(raw)
    }

    private static func decode(_ data: Data?) -> [JellyfinFeature: JellyfinFeatureSupport] {
        guard let data,
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let feature = JellyfinFeature(rawValue: key),
                  let support = JellyfinFeatureSupport(rawValue: value) else { return nil }
            return (feature, support)
        })
    }
}
