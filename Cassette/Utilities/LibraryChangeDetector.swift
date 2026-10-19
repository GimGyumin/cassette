// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Detects library changes between launches by comparing the server's reported media-file count
/// with the count recorded the last time this library was prepared.
///
/// The server count comes from `getScanStatus`; it moves whenever files are added or removed, which
/// is exactly the event the preparation screen exists for. Kept pure so the rule is unit-tested
/// without `UserDefaults` or a server.
nonisolated enum LibraryChangeDetector {

    static let revalidationInterval: TimeInterval = 24 * 60 * 60

    static func needsMetadataRefresh(lastIndexedAt: Date?, lastScan: Date?, now: Date = Date()) -> Bool {
        guard let lastIndexedAt else { return true }
        if let lastScan, lastScan > lastIndexedAt { return true }
        return now.timeIntervalSince(lastIndexedAt) >= revalidationInterval
    }

    /// Per-server storage key for the last-prepared media-file count.
    static func defaultsKey(serverId: UUID) -> String {
        "cassette.library.preparedCount.\(serverId.uuidString)"
    }

    /// Whether the library must be prepared again.
    ///
    /// - An unknown server count can't be compared (the server has never scanned) → no work.
    /// - An unknown stored count means this is the **first** observation for this server. Onboarding
    ///   already indexed and downloaded artwork for it, so the count is only recorded; the *next*
    ///   launch can then detect a real change. This is what stops the preparation screen appearing
    ///   immediately after sign-in.
    /// - A different count means tracks were added or removed → prepare.
    static func needsPreparation(storedCount: Int?, serverCount: Int?) -> Bool {
        guard let serverCount, let storedCount else { return false }
        return storedCount != serverCount
    }

    static func storedCount(for serverId: UUID, defaults: UserDefaults = .standard) -> Int? {
        let key = defaultsKey(serverId: serverId)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    static func store(count: Int, for serverId: UUID, defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: defaultsKey(serverId: serverId))
    }

    static func clear(for serverId: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(serverId: serverId))
    }
}
