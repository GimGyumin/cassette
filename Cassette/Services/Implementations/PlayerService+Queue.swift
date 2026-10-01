// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

// Actor-isolated implementation; PlayerService remains the single playback owner.
extension PlayerService {
    // MARK: - Smart Shuffle

    func playSmartShuffle() async throws {
        let tracks = try await libraryService.smartShuffleQueue(targetSize: 50)
        guard !tracks.isEmpty else {
            Logger.player.info("Smart shuffle returned empty — library too small or no downloads offline")
            throw CassetteError.smartShuffleEmpty
        }

        try await play(tracks: tracks, startIndex: 0)
        await MainActor.run { state.isSmartShuffleActive = true }

        Logger.player.info("Started Smart Shuffle session with \(tracks.count) tracks")
    }

    func setVolume(_ volume: Float) async {
        let clamped = max(0, min(1, volume))
        #if os(iOS)
        // SystemVolumeView owns iOS route volume. This method remains the software-volume
        // path for macOS only.
        _ = clamped
        #else
        setEngineVolume(clamped)
        if clamped > 0 {
            UserDefaults.standard.set(clamped, forKey: "cassette.lastVolume")
        }
        #endif
    }

    func replayGainSettingsDidChange() async {
        let (track, config) = await MainActor.run { (state.currentTrack, replayGainSettings.config) }
        await replayGainService?.apply(currentTrack: track, config: config)
    }

    func crossfadeSettingsDidChange() async {
        crossfadeConfig = await MainActor.run { crossfadeSettings.config }
        cancelGaplessBridge()
    }

    /// Updates the gapless snapshot. Enabling it mid-track arms the bridge immediately (so the
    /// user hears the change on the *next* transition); disabling it flushes any armed entry so a
    /// stale pre-buffer cannot auto-advance into a track the user did not want pre-fetched.
    func gaplessSettingsDidChange() async {
        let enabled = await MainActor.run { gaplessSettings.isEnabled }
        guard enabled != gaplessEnabled else { return }
        gaplessEnabled = enabled
        let label = enabled ? "enabled" : "disabled"
        Logger.player.info("[GAPLESS] \(label, privacy: .public) by the user")
        guard enabled else {
            cancelGaplessBridge()
            return
        }
        guard let song = await MainActor.run(body: { state.currentTrack }),
              let serverId = await MainActor.run(body: { serverService.state.activeServer?.id }) else {
            return
        }
        await scheduleGaplessPreQueue(current: song, serverId: serverId, epoch: playbackEpoch)
    }

    func setAutoExtendEnabled(_ enabled: Bool) async {
        await MainActor.run { state.isAutoExtendEnabled = enabled }
        UserDefaults.standard.set(enabled, forKey: Self.autoExtendUserDefaultsKey)
        if enabled {
            // Force: don't wait until ≤15 remain — populate the Autoplay section immediately.
            await evaluateAutoExtend(force: true)
        } else {
            await truncateExtensions()
        }
        Logger.player.info("Auto-extend \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    // MARK: - Auto-extend

    func evaluateAutoExtend(force: Bool = false) async {
        let (isEnabled, repeatMode, currentRadio, remaining, queueIds) = await MainActor.run {
            let remaining = state.queue.count - state.currentIndex - 1
            return (state.isAutoExtendEnabled, state.repeatMode, state.currentRadio, remaining, Set(state.queue.map(\.id)))
        }
        guard isEnabled else { return }
        guard repeatMode == .off else { return }
        guard currentRadio == nil else { return }
        guard autoExtendFetchTask == nil else { return }
        // Top up when the intentional tail is short, or when the user just turned Autoplay on.
        guard force || remaining <= 15 else { return }

        Logger.player.info(
            "Auto-extend triggered: \(remaining) tracks remaining force=\(force, privacy: .public), fetching 50 similar"
        )

        // Utility priority so backfill yields to audio streaming / UI.
        autoExtendFetchTask = Task(priority: .utility) { [libraryService, weak self] in
            defer { Task { await self?.clearAutoExtendFetchTask() } }
            do {
                let tracks = try await libraryService.similarBackfillQueue(targetSize: 50, excludedIds: queueIds)
                guard !tracks.isEmpty else {
                    Logger.player.debug("Auto-extend fetch returned empty")
                    return
                }
                await self?.anchorOriginalQueueBoundaryIfNeeded()
                await self?.appendToQueue(tracks)
                Logger.player.info("Auto-extend appended \(tracks.count) tracks to queue")
            } catch {
                Logger.player.debug("Auto-extend fetch failed: \(error, privacy: .public)")
            }
        }
    }

    private func clearAutoExtendFetchTask() {
        autoExtendFetchTask = nil
    }

    func anchorOriginalQueueBoundaryIfNeeded() async {
        let alreadySet = await MainActor.run { state.originalQueueEndIndex != nil }
        guard !alreadySet else { return }
        let queueCount = await MainActor.run { state.queue.count }
        await MainActor.run { state.originalQueueEndIndex = queueCount }
        Logger.player.debug("Auto-extend boundary anchored at \(queueCount)")
    }

    private func truncateExtensions() async {
        let (boundary, currentIndex, queueCount) = await MainActor.run {
            (state.originalQueueEndIndex, state.currentIndex, state.queue.count)
        }
        guard let boundary else { return }
        guard currentIndex < boundary else { return }
        guard boundary < queueCount else { return }
        await MainActor.run {
            state.queue = Array(state.queue[0..<boundary])
            state.originalQueueEndIndex = nil
        }
        Logger.player.info("Auto-extend tail truncated at boundary \(boundary) (currentIndex=\(currentIndex))")
    }

    // MARK: - Queue management

    func setRepeatMode(_ mode: RepeatMode) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("setRepeatMode ignored — live stream mode")
            return
        }
        let previousMode = await MainActor.run { state.repeatMode }
        cancelGaplessBridge()
        await MainActor.run { state.repeatMode = mode }
        if previousMode == .off && mode != .off {
            await truncateExtensions()
        }
        if previousMode != .off && mode == .off {
            await evaluateAutoExtend()
        }
        await saveSession()
    }

    func toggleShuffle() async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("toggleShuffle ignored — live stream mode")
            return
        }
        cancelGaplessBridge()
        let isCurrentlyShuffled = await MainActor.run { state.isShuffled }
        if isCurrentlyShuffled {
            await restoreOriginalQueueOrder()
            await MainActor.run { state.isShuffled = false }
        } else {
            await shuffleUpNext()
            await MainActor.run { state.isShuffled = true }
        }
        await saveSession()
    }

    private func shuffleUpNext() async {
        let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
        originalQueueOrder = queue
        guard currentIndex + 1 < queue.count else { return }
        let head = Array(queue[...currentIndex])
        let shuffled = Array(queue[(currentIndex + 1)...]).shuffled()
        await MainActor.run { state.queue = head + shuffled }
    }

    private func restoreOriginalQueueOrder() async {
        guard let original = originalQueueOrder,
              let currentTrack = await MainActor.run(body: { state.currentTrack }),
              let restoredIndex = original.firstIndex(where: { $0.id == currentTrack.id })
        else { return }
        await MainActor.run {
            state.queue = original
            state.currentIndex = restoredIndex
        }
        originalQueueOrder = nil
    }

    func appendToQueue(_ tracks: [DisplayableSong]) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("appendToQueue ignored — live stream mode")
            return
        }
        await MainActor.run { state.queue.append(contentsOf: tracks) }
        await saveSession()
    }

    func cancelGaplessBridge() {
        gaplessPreparationGeneration &+= 1
        nextGaplessPreparationAttempt = .distantPast
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = nil
        systemEngine.cancelQueuedItem()
        // Flush the AudioStreaming pre-queued entry so it can't auto-advance into a track the
        // user just re-ordered around (e.g. "Play Next" inserted before the armed next track).
        if let source = gaplessBridgeSource {
            engine.removeFromQueue(url: source.url)
        }
        gaplessBridgeNext = nil
        gaplessBridgeSource = nil
        gaplessBridgeEpoch = 0
        bridgedEntryDidStart = false
    }

    func playNext(_ songs: [DisplayableSong]) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("playNext ignored — live stream mode")
            return
        }
        let (queue, currentIndex) = await MainActor.run { (state.queue, state.currentIndex) }
        if queue.isEmpty {
            do {
                try await play(tracks: songs, startIndex: 0)
            } catch {
                Logger.player.error("[PLAYBACK] playNext: play() failed on empty queue: \(error, privacy: .public)")
            }
        } else {
            // The immediate next slot is being re-ordered — drop the armed gapless bridge so the
            // engine falls through to skipToNext()/play() and plays the inserted track next.
            cancelGaplessBridge()
            let insertAt = min(currentIndex + 1, queue.count)
            await MainActor.run { state.queue.insert(contentsOf: songs, at: insertAt) }
            Logger.player.info("Inserted \(songs.count) song(s) at queue position \(insertAt)")
            await saveSession()
            if !songs.isEmpty {
                await presentQueueConfirmation(
                    songs.count == 1
                        ? String(localized: "Playing next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                        : String(localized: "\(songs.count) songs playing next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    coverArtId: songs.first?.coverArtId
                )
            }
        }
    }

    func playNext(_ song: DisplayableSong) async {
        await playNext([song])
    }

    func addToQueue(_ songs: [DisplayableSong]) async {
        guard !songs.isEmpty else { return }
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("addToQueue ignored — live stream mode")
            return
        }
        // Insert before the autoplay (auto-extended) tail when one exists, so user-added tracks
        // play before autoplay-generated suggestions instead of after them.
        let (boundary, queueCount) = await MainActor.run {
            (state.originalQueueEndIndex, state.queue.count)
        }
        if let boundary, boundary < queueCount {
            cancelGaplessBridge()
            await MainActor.run {
                state.queue.insert(contentsOf: songs, at: boundary)
                state.originalQueueEndIndex = boundary + songs.count
            }
            await saveSession()
        } else {
            await appendToQueue(songs)
        }
        await presentQueueConfirmation(
            songs.count == 1
                ? String(localized: "Added to queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "\(songs.count) songs added to queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            coverArtId: songs.first?.coverArtId
        )
    }

    func addToQueue(_ song: DisplayableSong) async {
        await addToQueue([song])
    }

    private func presentQueueConfirmation(_ message: String, coverArtId: String? = nil) async {
        await MainActor.run { toastService.showConfirmation(message, coverArtId: coverArtId) }
    }

    func removeFromQueue(at index: Int) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("removeFromQueue ignored — live stream mode")
            return
        }
        let (queueCount, currentIndex, isShuffled) = await MainActor.run {
            (state.queue.count, state.currentIndex, state.isShuffled)
        }
        guard index >= 0, index < queueCount else { return }
        guard index != currentIndex else {
            Logger.player.warning("removeFromQueue: index \(index) is current track — ignored")
            return
        }
        cancelGaplessBridge()
        await MainActor.run {
            state.queue.remove(at: index)
            if index < state.currentIndex { state.currentIndex -= 1 }
            if let boundary = state.originalQueueEndIndex {
                if index < boundary {
                    state.originalQueueEndIndex = max(boundary - 1, state.currentIndex + 1)
                }
            }
        }
        if isShuffled { originalQueueOrder = nil }
        let newIdx = await MainActor.run { state.currentIndex }
        Logger.player.info("Removed track at \(index), currentIndex now \(newIdx)")
        await saveSession()
    }

    func clearQueueHistory() async {
        guard await MainActor.run(body: { !state.isLiveStream }) else { return }
        let (currentIndex, isShuffled) = await MainActor.run {
            (state.currentIndex, state.isShuffled)
        }
        guard currentIndex > 0 else { return }
        cancelGaplessBridge()
        await MainActor.run {
            state.queue.removeFirst(currentIndex)
            if let boundary = state.originalQueueEndIndex {
                state.originalQueueEndIndex = max(boundary - currentIndex, 1)
            }
            state.currentIndex = 0
        }
        if isShuffled { originalQueueOrder = nil }
        Logger.player.info("Cleared queue history (\(currentIndex) track(s))")
        await saveSession()
    }

    func clearUpNext() async {
        guard await MainActor.run(body: { !state.isLiveStream }) else { return }
        let (queueCount, currentIndex, isShuffled) = await MainActor.run {
            (state.queue.count, state.currentIndex, state.isShuffled)
        }
        guard currentIndex + 1 < queueCount else { return }
        cancelGaplessBridge()
        await MainActor.run {
            state.queue = Array(state.queue[0...currentIndex])
            state.originalQueueEndIndex = nil
        }
        if isShuffled { originalQueueOrder = nil }
        Logger.player.info("Cleared up next after index \(currentIndex)")
        await saveSession()
    }

    func moveInQueue(fromIndex: Int, toIndex: Int) async {
        guard await MainActor.run(body: { !state.isLiveStream }) else {
            Logger.player.debug("moveInQueue ignored — live stream mode")
            return
        }
        let (queueCount, currentIndex, isShuffled) = await MainActor.run {
            (state.queue.count, state.currentIndex, state.isShuffled)
        }
        guard fromIndex >= 0, fromIndex < queueCount else { return }
        guard toIndex >= 0, toIndex <= queueCount else { return }
        guard fromIndex != toIndex else { return }
        cancelGaplessBridge()
        await MainActor.run {
            let song = state.queue.remove(at: fromIndex)
            let dest = fromIndex < toIndex ? toIndex - 1 : toIndex
            state.queue.insert(song, at: dest)
            if fromIndex == currentIndex {
                state.currentIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
            } else if fromIndex < currentIndex && toIndex > currentIndex {
                state.currentIndex -= 1
            } else if fromIndex > currentIndex && toIndex <= currentIndex {
                state.currentIndex += 1
            }
        }
        if isShuffled { originalQueueOrder = nil }
        let newIdx = await MainActor.run { state.currentIndex }
        Logger.player.info("Moved track \(fromIndex)→\(toIndex), currentIndex now \(newIdx)")
        await saveSession()
    }
}
