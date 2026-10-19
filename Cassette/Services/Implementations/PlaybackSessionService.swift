// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog

/// Persists and restores playback sessions via SwiftData (CloudKit-backed).
///
/// Called on queue/track changes and pause, with a 30 s position checkpoint during playback.
/// Backgrounding flushes the current position immediately.
///
/// Without a unique constraint (CloudKit limitation), multiple `id == "current"`
/// rows can exist after sync. Restore and save use last-write-wins on `lastUpdated`.
actor PlaybackSessionService {
    private let modelContainer: ModelContainer
    /// Last persisted position — skip tiny deltas so SwiftData merges don't hitch the UI.
    private var lastSavedPosition: TimeInterval?
    private var lastSavedPayload: SessionPayload?
    private var lastSavedQueueData: Data?
    private var lastSavedUpdate: Date?
    private var lastSavedKey: String?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Full save — queue + position + current track metadata + repeat mode.
    func save(playerState: SessionPayload, identity: PlaybackCheckpointIdentity? = nil,
              publication: PlaybackPublication? = nil) {
        guard publication?.isCurrent != false else { return }
        if let identity {
            guard identity.trackID == playerState.currentTrack?.id,
                  identity.queueIndex == playerState.currentIndex,
                  playerState.queue.indices.contains(identity.queueIndex),
                  playerState.queue[identity.queueIndex].id == identity.trackID else { return }
        }
        let key = identity?.storageKey ?? "current"
        if lastSavedKey != key { resetSaveCache() }
        let modelContext = ModelContext(modelContainer)
        let session = fetchOrCreateSession(in: modelContext, accountID: identity?.accountID)
        session.id = key
        // A newer CloudKit winner invalidates our local no-op/queue cache.
        guard playerState != lastSavedPayload || session.lastUpdated != lastSavedUpdate else { return }
        let queueChanged = lastSavedPayload?.queue != playerState.queue
            || session.queueData != lastSavedQueueData
        session.update(
            currentIndex: playerState.currentIndex,
            currentPosition: playerState.currentPosition,
            queue: playerState.queue,
            currentTrack: playerState.currentTrack,
            repeatMode: playerState.repeatMode,
            encodeQueue: queueChanged
        )
        do {
            try modelContext.save()
            lastSavedKey = key
            lastSavedPayload = playerState
            lastSavedPosition = playerState.currentPosition
            lastSavedQueueData = session.queueData
            lastSavedUpdate = session.lastUpdated
        } catch {
            Logger.session.warning("PlaybackSessionService: save failed — \(error)")
        }
        Logger.session.debug("Session saved: track='\(playerState.currentTrack?.title ?? "nil", privacy: .private)', pos=\(playerState.currentPosition, format: .fixed(precision: 1), privacy: .public)s, queue=\(playerState.queue.count, privacy: .public) tracks")
    }

    /// Lightweight position-only checkpoint, also used for immediate background flushes.
    func savePosition(_ position: TimeInterval, identity: PlaybackCheckpointIdentity? = nil,
                      publication: PlaybackPublication? = nil) {
        guard position.isFinite, position >= 0, publication?.isCurrent != false else { return }
        let modelContext = ModelContext(modelContainer)
        guard let session = fetchWinningSession(in: modelContext, accountID: identity?.accountID) else { return }
        if let identity {
            guard session.id == identity.storageKey, session.currentTrackId == identity.trackID,
                  session.currentIndex == identity.queueIndex else { return }
        }
        let matchesLastSave = session.id == lastSavedKey && session.lastUpdated == lastSavedUpdate
        if matchesLastSave, let last = lastSavedPosition, abs(position - last) < 1.0 { return }
        session.currentPosition = position
        session.lastUpdated = Date()
        do {
            try modelContext.save()
            lastSavedKey = session.id
            lastSavedPosition = position
            // Preserve the known queue for the next full save, but don't mistake an older
            // pause snapshot for the now-persisted position.
            if matchesLastSave, let saved = lastSavedPayload {
                lastSavedPayload = SessionPayload(currentIndex: saved.currentIndex, currentPosition: position,
                    queue: saved.queue, currentTrack: saved.currentTrack, repeatMode: saved.repeatMode)
            } else {
                lastSavedPayload = nil
            }
            lastSavedQueueData = session.queueData
            lastSavedUpdate = session.lastUpdated
        } catch {
            Logger.session.warning("PlaybackSessionService: savePosition failed — \(error)")
        }
    }

    /// Extracts and returns restoration data, keeping @Model objects on this actor's context.
    /// Applies last-write-wins across CloudKit duplicates, then prunes losers.
    func loadRestoredSession(accountID: UUID? = nil) -> RestoredSession? {
        resetSaveCache()
        let modelContext = ModelContext(modelContainer)
        guard let session = consolidateToWinningSession(in: modelContext, accountID: accountID) else {
            Logger.session.info("No persisted session found")
            return nil
        }
        let queue = session.decodedQueue()
        guard !queue.isEmpty else {
            Logger.session.info("Persisted session has empty or unreadable queue — preserving for recovery")
            return nil
        }
        // Negative / out-of-range indices must not reach `queue[index]` (crash on restore).
        let safeIndex = max(0, min(session.currentIndex, queue.count - 1))
        if safeIndex != session.currentIndex {
            Logger.session.warning(
                "Session index \(session.currentIndex, privacy: .public) clamped to \(safeIndex, privacy: .public) (queue=\(queue.count, privacy: .public))"
            )
        }
        Logger.session.info("Session loaded: '\(session.currentTrackTitle ?? "nil", privacy: .private)', pos=\(session.currentPosition, format: .fixed(precision: 1), privacy: .public)s, \(queue.count, privacy: .public) tracks (updated \(session.lastUpdated, privacy: .public))")
        return RestoredSession(
            queue: queue,
            currentIndex: safeIndex,
            currentPosition: max(0, session.currentPosition),
            currentTrackDuration: max(0, session.currentTrackDuration),
            repeatMode: session.decodedRepeatMode()
        )
    }

    /// Read metadata for startup artwork preparation without restoring transport or resetting
    /// session checkpoint caches. Siri/live playback remains owned by PlayerService.
    func currentTrackForArtworkPreparation(accountID: UUID? = nil) -> DisplayableSong? {
        let modelContext = ModelContext(modelContainer)
        guard let session = fetchWinningSession(in: modelContext, accountID: accountID) else { return nil }
        let queue = session.decodedQueue()
        guard !queue.isEmpty else { return nil }
        return queue[max(0, min(session.currentIndex, queue.count - 1))]
    }

    func clear(accountID: UUID? = nil) {
        resetSaveCache()
        let modelContext = ModelContext(modelContainer)
        let sessions = fetchAllCurrentSessions(in: modelContext, accountID: accountID)
        guard !sessions.isEmpty else { return }
        for session in sessions {
            modelContext.delete(session)
        }
        do {
            try modelContext.save()
        } catch {
            Logger.session.warning("PlaybackSessionService: clear save failed — \(error)")
        }
        Logger.session.info("Session cleared")
    }

    // MARK: - LWW helpers

    private func resetSaveCache() {
        lastSavedKey = nil
        lastSavedPosition = nil
        lastSavedPayload = nil
        lastSavedQueueData = nil
        lastSavedUpdate = nil
    }

    private func fetchOrCreateSession(in modelContext: ModelContext, accountID: UUID? = nil) -> PlaybackSession {
        if let existing = consolidateToWinningSession(in: modelContext, accountID: accountID) { return existing }
        let new = PlaybackSession()
        modelContext.insert(new)
        return new
    }

    private func fetchWinningSession(in modelContext: ModelContext, accountID: UUID? = nil) -> PlaybackSession? {
        consolidateToWinningSession(in: modelContext, accountID: accountID)
    }

    /// Keeps the newest `lastUpdated` session with `id == "current"` and deletes the rest.
    @discardableResult
    private func consolidateToWinningSession(in modelContext: ModelContext, accountID: UUID? = nil) -> PlaybackSession? {
        let sessions = fetchAllCurrentSessions(in: modelContext, accountID: accountID)
        guard !sessions.isEmpty else { return nil }

        let sorted = sessions.sorted { $0.lastUpdated > $1.lastUpdated }
        guard let winner = sorted.first else { return nil }

        if sorted.count > 1 {
            for loser in sorted.dropFirst() {
                modelContext.delete(loser)
            }
            do {
                try modelContext.save()
                Logger.session.info("Session LWW: kept 1 of \(sessions.count, privacy: .public) CloudKit duplicates")
            } catch {
                Logger.session.warning("PlaybackSessionService: LWW prune failed — \(error)")
            }
        }
        return winner
    }

    private func fetchAllCurrentSessions(in modelContext: ModelContext, accountID: UUID? = nil) -> [PlaybackSession] {
        // At most one current row per account, plus pre-existing sync duplicates. Filtering this
        // small collection avoids changing the persisted model or guessing a legacy row's owner.
        let sessions = (try? modelContext.fetch(FetchDescriptor<PlaybackSession>())) ?? []
        if let accountID { return sessions.filter { $0.id.hasPrefix(PlaybackCheckpointIdentity.prefix(for: accountID)) } }
        return sessions.filter { $0.id == "current" }
    }

    func hasSession(for accountID: UUID) -> Bool {
        !fetchAllCurrentSessions(in: ModelContext(modelContainer), accountID: accountID).isEmpty
    }

    func hasLegacySession() -> Bool {
        let context = ModelContext(modelContainer)
        return fetchAllCurrentSessions(in: context).contains { !$0.decodedQueue().isEmpty }
    }

    /// Explicit recovery copies an unowned legacy queue; it never removes or relabels the
    /// original and never replaces a session already saved for the selected account.
    func copyLegacySession(to accountID: UUID, publication: PlaybackPublication) -> Bool {
        guard publication.isCurrent else { return false }
        let context = ModelContext(modelContainer)
        guard fetchAllCurrentSessions(in: context, accountID: accountID).isEmpty,
              let legacy = fetchAllCurrentSessions(in: context).max(by: { $0.lastUpdated < $1.lastUpdated }) else { return false }
        let queue = legacy.decodedQueue()
        guard !queue.isEmpty else { return false }
        let index = min(max(0, legacy.currentIndex), queue.count - 1)
        let identity = PlaybackCheckpointIdentity(accountID: accountID, trackID: queue[index].id,
            queueIndex: index, revision: UUID().uuidString)
        save(playerState: SessionPayload(currentIndex: index, currentPosition: max(0, legacy.currentPosition),
            queue: queue, currentTrack: queue[index], repeatMode: legacy.decodedRepeatMode()),
             identity: identity, publication: publication)
        return fetchAllCurrentSessions(in: ModelContext(modelContainer), accountID: accountID).contains { $0.id == identity.storageKey }
    }
}

// MARK: - SessionPayload

nonisolated struct SessionPayload: Sendable, Equatable {
    let currentIndex: Int
    let currentPosition: TimeInterval
    let queue: [DisplayableSong]
    let currentTrack: DisplayableSong?
    let repeatMode: RepeatMode
}

// MARK: - RestoredSession

/// Value-type snapshot passed to actor-isolated callers — avoids exposing @Model across actor boundary.
nonisolated struct RestoredSession: Sendable {
    let queue: [DisplayableSong]
    let currentIndex: Int
    let currentPosition: TimeInterval
    let currentTrackDuration: TimeInterval
    let repeatMode: RepeatMode
}
