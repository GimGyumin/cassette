// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Manages MPNowPlayingInfoCenter and MPRemoteCommandCenter.
/// Active from v1: lockscreen, Control Center, AirPods, Apple Watch.
/// Designed as the direct extension point for CarPlay in v1.2 — no refactor needed.
protocol NowPlayingServiceProtocol: AnyObject, Sendable {
    /// Registers remote command handlers and begins observing PlayerState.
    func start() async

    /// Deregisters all handlers and clears now playing info.
    func stop() async

    /// Releases reusable artwork without removing the currently displayed Now Playing item.
    func clearArtworkCache() async

    /// Pushes a full metadata + artwork update (called from PlayerService on track change or seek).
    func update(with snapshot: NowPlayingSnapshot) async

    /// Merges elapsed time, rate, and duration into the existing nowPlayingInfo dict without
    /// touching title, artist, or artwork. Called on every periodic tick to prevent iOS
    /// extrapolation drift on the lock screen.
    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async

    /// Patches ISRC into the current Now Playing info for system Music Haptics.
    func setISRC(_ isrc: String) async

    /// Immediately updates playback rate in Now Playing (Music Haptics follows this).
    func setPlaybackRate(_ rate: Float) async

    /// Removes ISRC from Now Playing so system Music Haptics detach from the prior track.
    func clearISRC() async

    /// Publishes title/artist/album/rate/ISRC without waiting for artwork (track transitions).
    func publishTrackChange(_ snapshot: NowPlayingSnapshot) async

    /// Re-enable skip / previous / scrub after sleep or route changes (CarPlay / lock screen).
    func reassertRemoteCommands() async
}
