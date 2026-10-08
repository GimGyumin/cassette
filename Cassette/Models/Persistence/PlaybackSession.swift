// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

/// Persisted playback session — logical singleton (`id == "current"`).
///
/// Stores the full queue as JSON so the MiniPlayer can restore instantly
/// without a network round-trip. Track metadata is duplicated as top-level
/// fields for fast MiniPlayer rendering before the full queue is decoded.
///
/// CloudKit does not support unique constraints; duplicates are resolved with
/// last-write-wins on `lastUpdated` in `PlaybackSessionService`.
@Model
final class PlaybackSession {
    var id: String = "current"
    var currentIndex: Int = 0
    var currentPosition: TimeInterval = 0
    var queueData: Data = Data()

    // Current track metadata — duplicated for fast MiniPlayer display
    var currentTrackId: String?
    var currentTrackTitle: String?
    var currentTrackArtist: String?
    var currentTrackCoverArtId: String?
    var currentTrackDuration: TimeInterval = 0
    var currentTrackIsDownloaded: Bool = false

    var lastUpdated: Date = Date()
    var repeatModeRaw: String = RepeatMode.off.rawValue

    init(
        currentIndex: Int = 0,
        currentPosition: TimeInterval = 0,
        queue: [DisplayableSong] = [],
        currentTrack: DisplayableSong? = nil,
        repeatMode: RepeatMode = .off
    ) {
        self.id = "current"
        self.currentIndex = currentIndex
        self.currentPosition = currentPosition
        self.queueData = (try? JSONEncoder().encode(queue)) ?? Data()
        self.currentTrackId = currentTrack?.id
        self.currentTrackTitle = currentTrack?.title
        self.currentTrackArtist = currentTrack?.artist
        self.currentTrackCoverArtId = currentTrack?.coverArtId
        self.currentTrackDuration = currentTrack?.duration ?? 0
        self.currentTrackIsDownloaded = currentTrack?.isDownloaded ?? false
        self.lastUpdated = Date()
        self.repeatModeRaw = repeatMode.rawValue
    }

    func decodedQueue() -> [DisplayableSong] {
        (try? JSONDecoder().decode([DisplayableSong].self, from: queueData)) ?? []
    }

    func decodedRepeatMode() -> RepeatMode {
        RepeatMode(rawValue: repeatModeRaw) ?? .off
    }

    func update(
        currentIndex: Int,
        currentPosition: TimeInterval,
        queue: [DisplayableSong],
        currentTrack: DisplayableSong?,
        repeatMode: RepeatMode,
        encodeQueue: Bool = true
    ) {
        self.currentIndex = currentIndex
        self.currentPosition = currentPosition
        if encodeQueue {
            self.queueData = (try? JSONEncoder().encode(queue)) ?? Data()
        }
        self.currentTrackId = currentTrack?.id
        self.currentTrackTitle = currentTrack?.title
        self.currentTrackArtist = currentTrack?.artist
        self.currentTrackCoverArtId = currentTrack?.coverArtId
        self.currentTrackDuration = currentTrack?.duration ?? 0
        self.currentTrackIsDownloaded = currentTrack?.isDownloaded ?? false
        self.lastUpdated = Date()
        self.repeatModeRaw = repeatMode.rawValue
    }
}
