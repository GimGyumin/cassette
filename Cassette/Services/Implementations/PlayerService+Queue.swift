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
        transportCommandID &+= 1
        let context = playbackContext
        let serverID = await MainActor.run { serverService.state.activeServer?.id }
        guard contextIsCurrent(context) else { return }
        let tracks = try await libraryService.smartShuffleQueue(targetSize: 50)
        let accountMatches = await MainActor.run { serverService.state.activeServer?.id == serverID }
        guard contextIsCurrent(context), accountMatches else { return }
        guard !tracks.isEmpty else {
            Logger.player.info("Smart shuffle returned empty — library too small or no downloads offline")
            throw CassetteError.smartShuffleEmpty
        }

        try await play(tracks: tracks, startIndex: 0)
        guard transportCommandID == context.command &+ 1, !Task.isCancelled else { return }
        await commitPresentation(playbackContext) { state in state.isSmartShuffleActive = true; return true }

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
        let context = playbackContext
        let (track, config) = await MainActor.run { (state.currentPlaybackTrack ?? state.currentTrack, replayGainSettings.config) }
        await applyReplayGain(track: track, config: config, context: context)
    }

    func crossfadeSettingsDidChange() async {
        crossfadeConfig = await MainActor.run { crossfadeSettings.config }
        cancelGaplessBridge()
    }

    func playbackVariantSettingsDidChange() async {
        cancelPendingPrefetch()
        cancelGaplessBridge()
        nextGaplessPreparationAttempt = .distantPast
        await ensureGaplessPreparation()
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
        await ensureGaplessPreparation()
    }

    func setAutoExtendEnabled(_ enabled: Bool) async {
        await MainActor.run { state.isAutoExtendEnabled = enabled }
        UserDefaults.standard.set(enabled, forKey: Self.autoExtendUserDefaultsKey)
        if enabled {
            // Force: don't wait until ≤15 remain — populate the Autoplay section immediately.
            await evaluateAutoExtend(force: true)
        } else {
            cancelAutoExtendFetch()
            await truncateExtensions()
        }
        Logger.player.info("Auto-extend \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    // MARK: - Auto-extend

    nonisolated static func allowsAutoExtend(enabled: Bool, repeatMode: RepeatMode, isLive: Bool) -> Bool {
        enabled && repeatMode == .off && !isLive
    }

    func evaluateAutoExtend(force: Bool = false) async {
        let (isEnabled, repeatMode, currentRadio, remaining, queueIds) = await MainActor.run {
            let remaining = state.queue.count - state.currentIndex - 1
            return (state.isAutoExtendEnabled, state.repeatMode, state.currentRadio, remaining, Set(state.queue.map(\.id)))
        }
        guard Self.allowsAutoExtend(enabled: isEnabled, repeatMode: repeatMode, isLive: currentRadio != nil) else { return }
        guard autoExtendFetchTask == nil else { return }
        // Top up when the intentional tail is short, or when the user just turned Autoplay on.
        guard force || remaining <= 15 else { return }

        Logger.player.info(
            "Auto-extend triggered: \(remaining) tracks remaining force=\(force, privacy: .public), fetching 50 similar"
        )

        let serverID = await MainActor.run { serverService.state.activeServer?.id }
        guard autoExtendFetchTask == nil, !Task.isCancelled else { return }
        autoExtendFetchGeneration &+= 1
        let generation = autoExtendFetchGeneration
        autoExtendFetchTask = Task(priority: .utility) { [weak self] in
            await self?.fetchAutoExtend(excluding: queueIds, serverID: serverID, generation: generation)
        }
    }

    func cancelAutoExtendFetch() {
        autoExtendFetchGeneration &+= 1
        autoExtendFetchTask?.cancel()
        autoExtendFetchTask = nil
    }

    private func fetchAutoExtend(excluding ids: Set<String>, serverID: UUID?, generation: UInt64) async {
        defer {
            if generation == autoExtendFetchGeneration { autoExtendFetchTask = nil }
        }
        do {
            let tracks = try await libraryService.similarBackfillQueue(targetSize: 50, excludedIds: ids)
            guard generation == autoExtendFetchGeneration, !Task.isCancelled else { return }
            await applyAutoExtend(tracks, serverID: serverID)
        } catch {
            Logger.player.debug("Auto-extend fetch failed: \(error, privacy: .public)")
        }
    }

    /// Check current policy and publish the boundary + new tail in one MainActor turn.
    func applyAutoExtend(_ tracks: [DisplayableSong], serverID: UUID?) async {
        let additions = await MainActor.run { () -> [DisplayableSong] in
            guard !Task.isCancelled, state.isAutoExtendEnabled, state.repeatMode == .off,
                  !state.isLiveStream, serverService.state.activeServer?.id == serverID else { return [] }
            var ids = Set(state.queue.map(\.id))
            let additions = tracks.filter { ids.insert($0.id).inserted }
            guard !additions.isEmpty else { return [] }
            if state.originalQueueEndIndex == nil { state.originalQueueEndIndex = state.queue.count }
            state.queue.append(contentsOf: additions)
            return additions
        }
        if !additions.isEmpty {
            if originalQueueOrder != nil { originalQueueOrder?.append(contentsOf: additions) }
            await saveSession()
        }
    }

    func anchorOriginalQueueBoundaryIfNeeded() async {
        await MainActor.run {
            if state.originalQueueEndIndex == nil { state.originalQueueEndIndex = state.queue.count }
        }
    }

    private func truncateExtensions() async {
        let kept = await MainActor.run { () -> Int? in
            guard let boundary = state.originalQueueEndIndex,
                  boundary >= 0, state.currentIndex < boundary, boundary < state.queue.count else { return nil }
            state.queue = Array(state.queue.prefix(boundary))
            state.originalQueueEndIndex = nil
            return boundary
        }
        if let kept, originalQueueOrder != nil { originalQueueOrder = Array(originalQueueOrder!.prefix(kept)) }
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
            cancelAutoExtendFetch()
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
        let (queue, currentIndex, boundary) = await MainActor.run { (state.queue, state.currentIndex, state.originalQueueEndIndex) }
        originalQueueOrder = queue
        guard currentIndex + 1 < queue.count else { return }
        let head = Array(queue[...currentIndex])
        let start = currentIndex + 1
        let split = max(start, min(boundary ?? queue.count, queue.count))
        let shuffled = Array(queue[start..<split]).shuffled() + Array(queue[split...]).shuffled()
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
        if originalQueueOrder != nil { originalQueueOrder?.append(contentsOf: tracks) }
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
        if let source = gaplessBridge.source {
            engine.removeFromQueue(url: source.url)
        }
        gaplessBridge.reset()
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
            if let current = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil,
               let originalIndex = originalQueueOrder?.firstIndex(where: { $0.id == current.id }) {
                originalQueueOrder?.insert(contentsOf: songs, at: originalIndex + 1)
            }
            await MainActor.run {
                let position = min(state.currentIndex + 1, state.queue.count)
                state.queue.insert(contentsOf: songs, at: position)
                if let boundary = state.originalQueueEndIndex, position <= boundary {
                    state.originalQueueEndIndex = boundary + songs.count
                }
            }
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
            if originalQueueOrder != nil { originalQueueOrder?.insert(contentsOf: songs, at: min(boundary, originalQueueOrder?.count ?? 0)) }
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
        cancelGaplessBridge()
        let changed = await MainActor.run { () -> Bool in
            guard !state.isLiveStream, state.queue.indices.contains(index), index != state.currentIndex else { return false }
            state.queue.remove(at: index)
            if index < state.currentIndex { state.currentIndex -= 1 }
            if let boundary = state.originalQueueEndIndex, index < boundary {
                state.originalQueueEndIndex = max(boundary - 1, state.currentIndex + 1)
            }
            return true
        }
        if changed { originalQueueOrder = nil; await saveSession() }
    }

    func clearQueueHistory() async {
        cancelGaplessBridge()
        let changed = await MainActor.run { () -> Bool in
            let currentIndex = state.currentIndex
            guard !state.isLiveStream, currentIndex > 0, state.queue.indices.contains(currentIndex) else { return false }
            state.queue.removeFirst(currentIndex)
            if let boundary = state.originalQueueEndIndex {
                state.originalQueueEndIndex = max(boundary - currentIndex, 1)
            }
            state.currentIndex = 0
            return true
        }
        if changed { originalQueueOrder = nil; await saveSession() }
    }

    func clearUpNext() async {
        cancelGaplessBridge()
        let changed = await MainActor.run { () -> Bool in
            let currentIndex = state.currentIndex
            guard !state.isLiveStream, state.queue.indices.contains(currentIndex),
                  currentIndex + 1 < state.queue.count else { return false }
            state.queue = Array(state.queue.prefix(currentIndex + 1))
            state.originalQueueEndIndex = nil
            return true
        }
        if changed { originalQueueOrder = nil; await saveSession() }
    }

    func moveInQueue(fromIndex: Int, toIndex: Int) async {
        cancelGaplessBridge()
        let changed = await MainActor.run { () -> Bool in
            guard !state.isLiveStream, state.queue.indices.contains(fromIndex),
                  (0...state.queue.count).contains(toIndex), fromIndex != toIndex else { return false }
            let currentIndex = state.currentIndex
            let song = state.queue.remove(at: fromIndex)
            let dest = fromIndex < toIndex ? toIndex - 1 : toIndex
            state.queue.insert(song, at: dest)
            if fromIndex == currentIndex {
                state.currentIndex = dest
            } else if fromIndex < currentIndex && toIndex > currentIndex {
                state.currentIndex -= 1
            } else if fromIndex > currentIndex && toIndex <= currentIndex {
                state.currentIndex += 1
            }
            return true
        }
        if changed { originalQueueOrder = nil; await saveSession() }
    }
}
