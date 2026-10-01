// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import SwiftData
import OSLog

/// Resolves remote-ID generations without mutating historical records or making assumptions
/// about ID length, alphabet, numeric form, UUID form, or reversibility.
@MainActor
final class MediaIdentityService {
    private let modelContainer: ModelContainer
    private static let maximumAliasDepth = 64

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    struct IdentitySnapshot: Sendable, Equatable {
        let localStableID: String
        let currentRemoteID: String
        let legacyRemoteIDs: [String]
        let jellyfinID: String?
        let needsRelink: Bool
    }

    func resolveCurrentID(
        _ remoteID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType
    ) -> String {
        guard !remoteID.isEmpty else { return remoteID }
        let context = ModelContext(modelContainer)
        let aliases = aliases(serverId: serverId, entityType: entityType, context: context)
        let byOldID = Dictionary(aliases.map { ($0.oldRemoteID, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.verifiedAt >= rhs.verifiedAt ? lhs : rhs
        })

        var current = remoteID
        var visited = Set<String>()
        var path: [RemoteIDAlias] = []
        for _ in 0..<Self.maximumAliasDepth {
            guard visited.insert(current).inserted else {
                Logger.server.error("Remote ID alias loop rejected for server \(serverId.uuidString, privacy: .public)")
                return remoteID
            }
            guard let alias = byOldID[current], alias.currentRemoteID != current else { break }
            path.append(alias)
            current = alias.currentRemoteID
        }

        // Path compression makes repeated Siri/queue/offline lookups O(1), while retaining
        // every historical OLD key as a valid entry point.
        if current != remoteID {
            for alias in path where alias.currentRemoteID != current {
                alias.currentRemoteID = current
                alias.verifiedAt = Date()
            }
            if context.hasChanges { try? context.save() }
        }
        return current
    }

    /// Includes both the supplied/current IDs and every known legacy ID. This is intentionally
    /// used for local stores so a pre-migration download remains playable before any rewrite.
    func candidateRemoteIDs(
        for remoteID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType
    ) -> [String] {
        let current = resolveCurrentID(remoteID, serverId: serverId, entityType: entityType)
        let context = ModelContext(modelContainer)
        let identities = identities(serverId: serverId, entityType: entityType, context: context)
        var result: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
        }
        append(remoteID)
        append(current)

        for identity in identities where identity.currentRemoteID == current
            || identity.currentRemoteID == remoteID
            || identity.legacyRemoteIDs.contains(remoteID)
            || identity.legacyRemoteIDs.contains(current) {
            append(identity.currentRemoteID)
            identity.legacyRemoteIDs.forEach { append($0) }
        }
        for alias in aliases(serverId: serverId, entityType: entityType, context: context) {
            if resolveWithoutSaving(alias.currentRemoteID, aliases: aliases(serverId: serverId, entityType: entityType, context: context)) == current {
                append(alias.oldRemoteID)
                append(alias.currentRemoteID)
            }
        }
        return result
    }

    @discardableResult
    func observe(
        remoteID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        jellyfinID: String? = nil
    ) -> String {
        let current = resolveCurrentID(remoteID, serverId: serverId, entityType: entityType)
        let context = ModelContext(modelContainer)
        if let identity = identities(serverId: serverId, entityType: entityType, context: context).first(where: {
            $0.currentRemoteID == current || $0.legacyRemoteIDs.contains(remoteID)
        }) {
            if let jellyfinID, !jellyfinID.isEmpty { identity.jellyfinID = jellyfinID }
            identity.updatedAt = Date()
            try? context.save()
            return identity.localStableID
        }
        let identity = RemoteMediaIdentity(
            serverId: serverId,
            entityType: entityType,
            currentRemoteID: current,
            legacyRemoteIDs: current == remoteID ? [] : [remoteID],
            jellyfinID: jellyfinID
        )
        context.insert(identity)
        try? context.save()
        return identity.localStableID
    }

    func identity(
        for remoteID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType
    ) -> IdentitySnapshot? {
        let current = resolveCurrentID(remoteID, serverId: serverId, entityType: entityType)
        let context = ModelContext(modelContainer)
        guard let value = identities(serverId: serverId, entityType: entityType, context: context).first(where: {
            $0.currentRemoteID == current || $0.legacyRemoteIDs.contains(remoteID)
        }) else { return nil }
        return IdentitySnapshot(
            localStableID: value.localStableID,
            currentRemoteID: value.currentRemoteID,
            legacyRemoteIDs: value.legacyRemoteIDs,
            jellyfinID: value.jellyfinID,
            needsRelink: value.needsRelink
        )
    }

    func identity(
        localStableID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType
    ) -> IdentitySnapshot? {
        let context = ModelContext(modelContainer)
        guard let value = identities(serverId: serverId, entityType: entityType, context: context)
            .first(where: { $0.localStableID == localStableID }) else { return nil }
        return IdentitySnapshot(
            localStableID: value.localStableID,
            currentRemoteID: value.currentRemoteID,
            legacyRemoteIDs: value.legacyRemoteIDs,
            jellyfinID: value.jellyfinID,
            needsRelink: value.needsRelink
        )
    }

    func setNeedsRelink(
        _ needsRelink: Bool,
        remoteID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType
    ) {
        let current = resolveCurrentID(remoteID, serverId: serverId, entityType: entityType)
        let context = ModelContext(modelContainer)
        let values = identities(serverId: serverId, entityType: entityType, context: context)
        let identity: RemoteMediaIdentity
        if let existing = values.first(where: {
            $0.currentRemoteID == current || $0.legacyRemoteIDs.contains(remoteID)
        }) {
            identity = existing
        } else {
            identity = RemoteMediaIdentity(
                serverId: serverId,
                entityType: entityType,
                currentRemoteID: current,
                legacyRemoteIDs: current == remoteID ? [] : [remoteID]
            )
            context.insert(identity)
        }
        identity.needsRelink = needsRelink
        identity.updatedAt = Date()
        try? context.save()
    }

    /// Adds an idempotent verified alias. A mapping which would create a loop is rejected.
    @discardableResult
    func registerAlias(
        oldID: String,
        newID: String,
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        verificationSource: RemoteIDVerificationSource,
        confidence: Double,
        jellyfinID: String? = nil
    ) -> Bool {
        guard !oldID.isEmpty, !newID.isEmpty else { return false }
        if oldID == newID {
            _ = observe(remoteID: newID, serverId: serverId, entityType: entityType, jellyfinID: jellyfinID)
            return true
        }
        let target = resolveCurrentID(newID, serverId: serverId, entityType: entityType)
        let source = resolveCurrentID(oldID, serverId: serverId, entityType: entityType)
        if source == target, oldID != target {
            // The same migration may run after interruption. The chain already reaches the
            // requested target, so this is an idempotent success rather than a false loop.
            _ = observe(
                remoteID: target,
                serverId: serverId,
                entityType: entityType,
                jellyfinID: jellyfinID
            )
            return true
        }
        guard target != oldID, target != source else {
            Logger.server.error("Refused cyclic remote ID alias for server \(serverId.uuidString, privacy: .public)")
            return false
        }

        let context = ModelContext(modelContainer)
        let key = RemoteIDAlias.key(serverId: serverId, entityType: entityType, oldRemoteID: oldID)
        var descriptor = FetchDescriptor<RemoteIDAlias>(predicate: #Predicate { $0.compositeKey == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.currentRemoteID = target
            existing.verifiedAt = Date()
            existing.confidence = max(existing.confidence, min(max(confidence, 0), 1))
            existing.verificationSourceRaw = verificationSource.rawValue
        } else {
            context.insert(RemoteIDAlias(
                serverId: serverId,
                entityType: entityType,
                oldRemoteID: oldID,
                currentRemoteID: target,
                confidence: min(max(confidence, 0), 1),
                verificationSource: verificationSource
            ))
        }

        let scopedIdentities = identities(serverId: serverId, entityType: entityType, context: context)
        let oldIdentity = scopedIdentities.first { $0.currentRemoteID == oldID || $0.legacyRemoteIDs.contains(oldID) }
        let targetIdentity = scopedIdentities.first { $0.currentRemoteID == target || $0.legacyRemoteIDs.contains(target) }
        let identity = targetIdentity ?? oldIdentity ?? RemoteMediaIdentity(
            serverId: serverId,
            entityType: entityType,
            currentRemoteID: target
        )
        if targetIdentity == nil && oldIdentity == nil { context.insert(identity) }
        identity.currentRemoteID = target
        var legacy = identity.legacyRemoteIDs
        for value in [oldID, source] where value != target && !legacy.contains(value) { legacy.append(value) }
        identity.legacyRemoteIDs = legacy
        if let jellyfinID, !jellyfinID.isEmpty { identity.jellyfinID = jellyfinID }
        identity.updatedAt = Date()
        identity.needsRelink = false

        if let oldIdentity, oldIdentity !== identity {
            for value in oldIdentity.legacyRemoteIDs + [oldIdentity.currentRemoteID]
            where value != target && !identity.legacyRemoteIDs.contains(value) {
                identity.legacyRemoteIDs.append(value)
            }
            context.delete(oldIdentity)
        }
        try? context.save()
        _ = resolveCurrentID(oldID, serverId: serverId, entityType: entityType)
        return true
    }

    private func aliases(
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        context: ModelContext
    ) -> [RemoteIDAlias] {
        let sid = serverId
        let type = entityType.rawValue
        return (try? context.fetch(FetchDescriptor<RemoteIDAlias>(predicate: #Predicate {
            $0.serverId == sid && $0.entityTypeRaw == type
        }))) ?? []
    }

    private func identities(
        serverId: UUID,
        entityType: RemoteMediaEntityType,
        context: ModelContext
    ) -> [RemoteMediaIdentity] {
        let sid = serverId
        let type = entityType.rawValue
        return (try? context.fetch(FetchDescriptor<RemoteMediaIdentity>(predicate: #Predicate {
            $0.serverId == sid && $0.entityTypeRaw == type
        }))) ?? []
    }

    private func resolveWithoutSaving(_ remoteID: String, aliases: [RemoteIDAlias]) -> String {
        let byOldID = Dictionary(aliases.map { ($0.oldRemoteID, $0.currentRemoteID) }, uniquingKeysWith: { _, rhs in rhs })
        var current = remoteID
        var visited = Set<String>()
        for _ in 0..<Self.maximumAliasDepth {
            guard visited.insert(current).inserted, let next = byOldID[current], next != current else { break }
            current = next
        }
        return current
    }
}
