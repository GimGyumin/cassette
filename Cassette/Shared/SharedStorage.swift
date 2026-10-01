// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog

nonisolated enum SharedStorage {
    /// Must match App Groups in Cassette.entitlements / widget entitlements.
    static let appGroupID = "group.com.kyumin.Cassette"

    /// Local logger — this file is shared with the widget target (no Cassette Logger helpers).
    private static let log = Logger(subsystem: "app.cassette.shared", category: "SharedStorage")

    /// Serial queue for all App Group UserDefaults I/O. Opening / writing the suite on the
    /// main thread can stall while cfprefsd logs the benign `kCFPreferencesAnyUser` warning.
    private static let ioQueueKey = DispatchSpecificKey<UInt8>()
    private static let ioQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "app.cassette.shared-storage", qos: .utility)
        queue.setSpecific(key: ioQueueKey, value: 1)
        return queue
    }()

    private static let suiteLock = NSLock()
    private static var _sharedSuite: UserDefaults?
    private static var suiteResolved = false

    /// Lazily open the App Group suite off the hot path.
    private static func resolvedSuite() -> UserDefaults? {
        suiteLock.lock()
        defer { suiteLock.unlock() }
        if suiteResolved { return _sharedSuite }
        suiteResolved = true

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            log.error(
                "App Group \(appGroupID, privacy: .public) container unavailable — widgets will not sync. Enable App Groups on the App ID and refresh provisioning."
            )
            _sharedSuite = nil
            return nil
        }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        guard let suite = UserDefaults(suiteName: appGroupID) else {
            log.error(
                "App Group UserDefaults suite \(appGroupID, privacy: .public) failed to open — falling back to standard defaults."
            )
            _sharedSuite = nil
            return nil
        }
        // One-shot cfprefsd "kCFPreferencesAnyUser" warnings when first touching the suite are
        // expected on Simulator; the suite still works when the container URL exists.
        _sharedSuite = suite
        return suite
    }

    /// UserDefaults shared between app and widget extension when App Group is provisioned.
    /// Prefer `write` / `read` so access stays off the main thread.
    static var defaults: UserDefaults {
        resolvedSuite() ?? .standard
    }

    static var isAppGroupAvailable: Bool { resolvedSuite() != nil }

    /// Write App Group prefs on a utility queue (never blocks the main actor on cfprefsd).
    static func write(_ body: @escaping (UserDefaults) -> Void) {
        ioQueue.async {
            body(defaults)
        }
    }

    /// Read App Group prefs from the utility queue (safe from main when a sync result is needed).
    static func read<T>(_ body: (UserDefaults) -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            return body(defaults)
        }
        return ioQueue.sync {
            body(defaults)
        }
    }

    /// File container shared between app and widget extension.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Subdirectory for cover art cache inside the App Group container.
    static var coverArtCacheDirectory: URL? {
        containerURL?.appendingPathComponent("CoverArt", isDirectory: true)
    }

    static func ensureDirectoriesExist() throws {
        guard let coverDir = coverArtCacheDirectory else { return }
        try FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
    }
}

nonisolated enum SharedStorageKey: String {
    case recentlyPlayedItems
    case pinnedItems
    case dominantColors
    case nowPlayingState
}

/// Stable cross-process DTO for a recently played track.
/// Never rename fields — UserDefaults persists JSON between app and widget processes.
nonisolated struct SharedTrackInfo: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumID: String?
    /// Filename relative to SharedStorage.coverArtCacheDirectory, nil if not cached yet.
    let coverArtFilename: String?
}

/// Stable cross-process DTO for a pinned item.
/// Never rename fields — UserDefaults persists JSON between app and widget processes.
nonisolated struct SharedPinnedItem: Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case album, playlist, song, artist
    }

    let id: String
    let kind: Kind
    let title: String
    /// Artist for album, track count for playlist.
    let subtitle: String?
    /// Filename relative to SharedStorage.coverArtCacheDirectory, nil if not cached yet.
    let coverArtFilename: String?
}
