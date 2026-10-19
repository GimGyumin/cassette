// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

protocol PlayerServiceProtocol: AnyObject, Sendable {
    /// Observable playback state (MainActor-isolated).
    /// Consumed by MiniPlayer, FullPlayer, NowPlayingService, and (v1.2) CarPlay scene.
    /// Never duplicate this state in a view model.
    var state: PlayerState { get }

    /// Resolved playback route, without credentials or stream URLs.
    func playbackDetails() async -> PlaybackDetails?

    func play(tracks: [DisplayableSong], startIndex: Int) async throws
    func resume() async
    func pause() async
    func stop() async
    func skipToNext() async throws
    func skipToPrevious() async throws
    func seek(to position: TimeInterval) async
    func setRepeatMode(_ mode: RepeatMode) async
    func toggleShuffle() async
    func appendToQueue(_ tracks: [DisplayableSong]) async
    func playNext(_ song: DisplayableSong) async
    func playNext(_ songs: [DisplayableSong]) async
    func addToQueue(_ song: DisplayableSong) async
    func addToQueue(_ songs: [DisplayableSong]) async
    func removeFromQueue(at index: Int) async
    /// Drops every track before the current one (queue History section).
    func clearQueueHistory() async
    /// Drops every track after the current one (Up Next + Autoplay).
    func clearUpNext() async
    func moveInQueue(fromIndex: Int, toIndex: Int) async
    func restoreSession() async
    func restoreLegacySession() async
    func handleNetworkRestored() async
    /// Starts live stream playback of an Internet Radio Station.
    /// Clears the current queue's playing state but preserves the queue itself.
    func playRadio(_ station: InternetRadioStation) async throws
    /// Builds a Smart Shuffle queue via LibraryService and starts playback. Replaces the current queue.
    /// Throws `CassetteError.smartShuffleEmpty` if no eligible tracks (library too small / no downloads offline).
    func playSmartShuffle() async throws
    /// Toggles the auto-extend preference and persists it to UserDefaults.
    /// When enabled and ≤15 tracks remain, the player appends a fresh smart shuffle batch automatically.
    func setAutoExtendEnabled(_ enabled: Bool) async
    /// Applies the given volume (0.0–1.0) to AVPlayer and persists it to UserDefaults.
    func setVolume(_ volume: Float) async
    func togglePlayPause() async
    /// Lightweight position-only flush — used on background / kill-guard checkpoints.
    func saveCurrentPosition() async
    /// Re-assert audio session / engine after returning from background or app switcher.
    func handleAppBecameActive() async
    /// Brief inactive (Control Center) — no engine rebuild scheduling.
    func handleAppWillResignActive() async
    /// True background — may health-check AudioStreaming on return (stuck/crackle buffer).
    func handleAppDidEnterBackground() async
    /// Re-reads ReplayGainSettings and reapplies gain to the current track.
    /// Call this whenever the user changes any ReplayGain setting.
    func replayGainSettingsDidChange() async
    /// Updates the stored CrossfadeConfig snapshot from CrossfadeSettings.
    /// Call whenever the user changes any crossfade setting.
    func crossfadeSettingsDidChange() async
    /// Updates the stored gapless snapshot from GaplessSettings, arming or flushing the
    /// engine's pre-buffered next entry. Call whenever the user toggles gapless playback.
    func gaplessSettingsDidChange() async
    func playbackVariantSettingsDidChange() async
    /// Stops the audio engine synchronously without going through the actor.
    /// Only safe to call during app termination (single-threaded, no concurrent access).
    nonisolated func stopAudioEngineSync()
}

extension PlayerServiceProtocol {
    func restoreLegacySession() async {}
    func playbackVariantSettingsDidChange() async {}
    func playbackDetails() async -> PlaybackDetails? { nil }
}
