// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// The seam between App Intents (which the system may run before, during, or
/// after app launch) and Cassette's injected services.
///
/// Mirrors the existing `NowPlayingBridge` pattern: `AppContainer` injects a
/// closure during init — no new global singleton, and tests inject a fake.
/// The closure itself decides whether the app is ready yet, so Siri requests
/// that arrive during a cold start can wait for boot instead of failing.
@available(iOS 27.0, macOS 27.0, *)
nonisolated enum SiriBridge {
    /// Resolves the live Siri catalog. Returns `nil` when the app has no active
    /// server or the bootstrap has not finished.
    ///
    /// `nonisolated(unsafe)` matches `NowPlayingBridge`: written once on the
    /// MainActor during `AppContainer` init and read from non-isolated contexts.
    nonisolated(unsafe) static var catalogProvider: (@Sendable () async -> (any SiriCatalogServiceProtocol)?)?

    /// Resolves the player. Returns `nil` before `AppContainer` wires it.
    nonisolated(unsafe) static var playbackProvider: (@Sendable () async -> (any PlayerServiceProtocol)?)?

    /// Resolves the favorites service (for affinity / add-to-library).
    /// Non-`@Sendable`: `FavoritesServiceProtocol` is `AnyObject` (not Sendable);
    /// callers are MainActor-bound anyway.
    nonisolated(unsafe) static var favoritesProvider: (() async -> (any FavoritesServiceProtocol)?)?

    /// Resolves the playlist service (for add-to-playlist).
    nonisolated(unsafe) static var playlistProvider: (@Sendable () async -> (any PlaylistServiceProtocol)?)?

    /// Opens a Cassette entity deep link in the host app.
    nonisolated(unsafe) static var openURLAction: (@Sendable (URL) async -> Void)?

    /// Waits for the app to finish booting (`AppContainer` init + persisted-server load)
    /// before a Siri request touches any provider. Prevents "can't play" on cold starts,
    /// where the intent or query can run before the SwiftUI scene has wired the bridge.
    static func waitUntilReady() async {
        await SiriBootGate.waitUntilReady()
    }
}

