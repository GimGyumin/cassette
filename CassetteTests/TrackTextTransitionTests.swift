// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Testing
@testable import Cassette

@Suite("Track title transition direction")
struct TrackTextTransitionTests {
    private func key(_ track: String?, _ index: Int, _ count: Int = 4, first: String? = "a") -> TrackSnapshotKey {
        TrackSnapshotKey(trackID: track, index: index, queueCount: count, firstTrackID: first)
    }

    @Test func nextTrackSlidesForward() {
        let direction = TrackSnapshotKey.direction(
            from: key("a", 0),
            to: key("b", 1),
            repeatAll: false
        )
        #expect(direction == .forward)
    }

    @Test func previousTrackSlidesBackward() {
        let direction = TrackSnapshotKey.direction(
            from: key("c", 2),
            to: key("b", 1),
            repeatAll: false
        )
        #expect(direction == .backward)
    }

    @Test func repeatAllWrapIsForward() {
        let direction = TrackSnapshotKey.direction(
            from: key("d", 3),
            to: key("a", 0),
            repeatAll: true
        )
        #expect(direction == .forward)
    }

    @Test func repeatAllPreviousWrapIsBackward() {
        let direction = TrackSnapshotKey.direction(
            from: key("a", 0),
            to: key("d", 3),
            repeatAll: true
        )
        #expect(direction == .backward)
    }

    @Test func nonRepeatWrapSlidesBackward() {
        let direction = TrackSnapshotKey.direction(
            from: key("d", 3),
            to: key("a", 0),
            repeatAll: false
        )
        #expect(direction == .backward)
    }

    @Test func changedQueueFades() {
        let direction = TrackSnapshotKey.direction(
            from: key("a", 0, 4, first: "a"),
            to: key("x", 0, 8, first: "x"),
            repeatAll: false
        )
        #expect(direction == .fade)
    }

    @Test func sameIndexReplacementFades() {
        let direction = TrackSnapshotKey.direction(
            from: key("a", 1),
            to: key("b", 1),
            repeatAll: false
        )
        #expect(direction == .fade)
    }

    @Test func sameSongAtAnotherQueuePositionDoesNotAnimate() {
        let old = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 4, firstTrackID: "a")
        let new = TrackSnapshotKey(trackID: "a", index: 2, queueCount: 4, firstTrackID: "a")
        #expect(!TrackSnapshotKey.isTrackChange(from: old, to: new))
    }

    @Test func directionForDuplicatePositionIsStillForward() {
        let direction = TrackSnapshotKey.direction(
            from: key("a", 0),
            to: key("a", 1),
            repeatAll: false
        )
        #expect(direction == .forward)
    }

    @Test func queueAppendDoesNotCountAsTrackChange() {
        let old = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 4, firstTrackID: "a")
        let new = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 5, firstTrackID: "a")
        #expect(!TrackSnapshotKey.isTrackChange(from: old, to: new))
    }

    @Test func removingEarlierQueueItemDoesNotCountAsTrackChange() {
        let old = TrackSnapshotKey(trackID: "a", index: 3, queueCount: 5, firstTrackID: "a")
        let new = TrackSnapshotKey(trackID: "a", index: 2, queueCount: 4, firstTrackID: "a")
        #expect(!TrackSnapshotKey.isTrackChange(from: old, to: new))
    }

    @Test func differentTrackAtSamePositionIsATrackChange() {
        let old = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 4, firstTrackID: "a")
        let new = TrackSnapshotKey(trackID: "b", index: 1, queueCount: 4, firstTrackID: "a")
        #expect(TrackSnapshotKey.isTrackChange(from: old, to: new))
    }

    @Test func contentIDIgnoresQueueEdits() {
        let before = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 4, firstTrackID: "a")
        let after = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 5, firstTrackID: "a")
        #expect(before.contentID == after.contentID)
    }

    @Test func contentIDIncludesQueuePosition() {
        let first = TrackSnapshotKey(trackID: "a", index: 1, queueCount: 4, firstTrackID: "a")
        let second = TrackSnapshotKey(trackID: "a", index: 2, queueCount: 4, firstTrackID: "a")
        #expect(first.contentID != second.contentID)
    }
}
