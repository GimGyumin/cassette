// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import SwiftData

/// Remote identifiers are opaque strings. The cases only scope aliases so an album ID can
/// never accidentally rewrite a song, playlist, or artwork identifier with the same value.
enum RemoteMediaEntityType: String, Codable, Sendable, CaseIterable {
    case song
    case album
    case artist
    case playlist
    case coverArt
}

enum RemoteIDVerificationSource: String, Codable, Sendable {
    case serverResponse
    case externalIdentifier
    case exactPath
    case strictMetadata
    case userConfirmed
}

/// Permanent, server-scoped OLD -> NEW mapping. Old rows are deliberately retained: queues,
/// Siri/Spotlight entities and offline records may continue to contain any historic ID.
@Model
final class RemoteIDAlias {
    @Attribute(.unique) var compositeKey: String
    var serverId: UUID
    var entityTypeRaw: String
    var oldRemoteID: String
    var currentRemoteID: String
    var verifiedAt: Date
    var confidence: Double
    var verificationSourceRaw: String

    init(
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        oldRemoteID: String,
        currentRemoteID: String,
        verifiedAt: Date = Date(),
        confidence: Double,
        verificationSource: RemoteIDVerificationSource
    ) {
        self.compositeKey = Self.key(serverId: serverId, entityType: entityType, oldRemoteID: oldRemoteID)
        self.serverId = serverId
        self.entityTypeRaw = entityType.rawValue
        self.oldRemoteID = oldRemoteID
        self.currentRemoteID = currentRemoteID
        self.verifiedAt = verifiedAt
        self.confidence = confidence
        self.verificationSourceRaw = verificationSource.rawValue
    }

    static func key(serverId: UUID, entityType: RemoteMediaEntityType, oldRemoteID: String) -> String {
        "\(serverId.uuidString):\(entityType.rawValue):\(oldRemoteID)"
    }
}

/// Cassette-owned identity which remains stable while a server changes the IDs it exposes.
/// Jellyfin GUIDs are stored only when returned by the server; Cassette never guesses or
/// converts them from a Navidrome ID.
@Model
final class RemoteMediaIdentity {
    @Attribute(.unique) var localStableID: String
    var serverId: UUID
    var entityTypeRaw: String
    var currentRemoteID: String
    var legacyRemoteIDs: [String]
    var jellyfinID: String?
    var updatedAt: Date
    var needsRelink: Bool

    init(
        localStableID: String = UUID().uuidString,
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        currentRemoteID: String,
        legacyRemoteIDs: [String] = [],
        jellyfinID: String? = nil,
        updatedAt: Date = Date(),
        needsRelink: Bool = false
    ) {
        self.localStableID = localStableID
        self.serverId = serverId
        self.entityTypeRaw = entityType.rawValue
        self.currentRemoteID = currentRemoteID
        self.legacyRemoteIDs = legacyRemoteIDs
        self.jellyfinID = jellyfinID
        self.updatedAt = updatedAt
        self.needsRelink = needsRelink
    }
}

