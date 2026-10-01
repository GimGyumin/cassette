// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import MediaPlayer
import OSLog
#if os(iOS)
import UIKit
#endif

/// Manages MPNowPlayingInfoCenter + MPRemoteCommandCenter.
/// Active from v1 (lockscreen, Control Center, AirPods, Apple Watch).
/// Architected as the direct extension point for CarPlay (v1.2) — no refactor needed.
actor NowPlayingService: NowPlayingServiceProtocol {
    enum RemoteCommand: Sendable {
        case play
        case pause
        case toggle
        case next
        case previous
        case seek(TimeInterval)
    }

    let playerService: any PlayerServiceProtocol
    let artworkLoader = ArtworkLoader()
    let artworkImageCache: ArtworkImageCache
    let serverState: ServerState?
    /// Album id → the cover a downloaded album stored during library preparation. Lets the lock
    /// screen prefer downloaded artwork over a server fetch, matching the in-app player.
    let preparedCoverIdProvider: (@MainActor (String?) -> String?)?
    var modernMediaSession: AnyObject?
    var commandsRegistered = false
    var currentSong: NowPlayingSnapshot?
    var artworkGeneration = 0
    var hasArtwork = false
    var artworkRetryDate = Date.distantPast
    var artworkRetryAttempt = 0
    var artworkRetryTask: Task<Void, Never>?
    nonisolated static let maximumArtworkRetryAttempts = 3
    let artworkRevision = NowPlayingArtworkRevision()
    /// Failed current-track artwork is retried with a bounded exponential backoff and once
    /// again on foreground entry. This avoids both a blank Watch/lock screen and an endless
    /// 30-second network retry loop for tracks whose server artwork is permanently missing.
    var pendingArtwork: (snapshot: NowPlayingSnapshot, headers: [String: String])?
    var foregroundRetryObserver: NSObjectProtocol?
    var originalArtworkObserver: NSObjectProtocol?
    /// Remote events can arrive in a burst (for example a lock-screen tap followed by an
    /// AirPods gesture). Keep their order instead of letting detached tasks race each other.
    var remoteCommandTail: Task<Void, Never>?

    init(
        playerService: any PlayerServiceProtocol,
        artworkImageCache: ArtworkImageCache,
        serverState: ServerState? = nil,
        preparedCoverIdProvider: (@MainActor (String?) -> String?)? = nil
    ) {
        self.playerService = playerService
        self.artworkImageCache = artworkImageCache
        self.serverState = serverState
        self.preparedCoverIdProvider = preparedCoverIdProvider
    }

    func stop() async {
        artworkRetryTask?.cancel()
        artworkRetryTask = nil
        artworkGeneration &+= 1
        let generation = artworkGeneration
        currentSong = nil
        pendingArtwork = nil
        hasArtwork = false
        artworkRetryAttempt = 0
        artworkRetryDate = .distantPast
        #if os(iOS)
        if #available(iOS 27.0, *),
           let controller = modernMediaSession as? CassetteMediaSessionController {
            await controller.stop()
        }
        #endif
        await MainActor.run {
            guard artworkRevision.accept(generation) else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            #endif
        }
        #if os(macOS)
        postDiscordRPC(.stopped)
        #endif
    }

    func clearArtworkCache() async {
        await artworkLoader.clearCache()
    }

}
