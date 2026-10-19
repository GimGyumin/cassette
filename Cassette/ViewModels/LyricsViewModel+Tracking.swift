// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine
import OSLog
import QuartzCore

extension LyricsViewModel {
    // MARK: Line Tracking

    /// Whether these lyrics have real per-line timestamps we can follow during playback.
    /// Servers sometimes mark plain text as `synced`, or stamp every line with `start: 0`.
    var followsPlayback: Bool {
        hasTimedPlayback
    }

    nonisolated static func hasUsableTiming(_ structured: StructuredLyrics) -> Bool {
        var firstStart: Int?
        for line in structured.line {
            guard let start = line.start else { continue }
            if let firstStart {
                if start != firstStart { return true }
            } else {
                firstStart = start
            }
        }
        return false
    }

    func update(elapsedMs: Int) {

        guard case .loaded(let structured) = state else {
            clearLineHighlight()
            clearInstrumentalGap()
            return
        }

        guard followsPlayback else {
            if currentLineIndex != nil || !activeLineIndices.isEmpty {
                clearLineHighlight()
            }
            clearInstrumentalGap()
            return
        }

        // Apple Music: displayTime = playerTime + lyricOffset (from <audio lyricOffset="..."/>).
        let lyricOffsetMs = lyricDocument.map {
            LyricTime.milliseconds(fromSeconds: $0.lyricOffset)
        } ?? 0
        let requestedMs = elapsedMs - structured.offset + lyricOffsetMs
        // Use one clock for line selection and word fill. Absorb only sub-frame-ish
        // timestamp jitter; larger backward corrections are authoritative player resyncs
        // (for example after buffering) and must not leave lyrics running ahead of audio.
        let backwardCorrectionMs = karaokePlaybackMs - requestedMs
        let baseMs = backwardCorrectionMs > 0 && backwardCorrectionMs <= 120
            ? karaokePlaybackMs : requestedMs
        let timedLines = playbackTimeline.activeRows(for: baseMs)
        let adjustedMs = baseMs

        var newPrimary = timedLines.primary
        var newActive = timedLines.indices

        // Detect a long instrumental gap on EVERY tick. `activeRows` hides the "nothing is
        // singing" state two ways: lines without an `endMs` stay "singing" forever, and its
        // fallback auto-advances to the next line when no line is active. Long gaps therefore
        // never produced an empty `newActive`, so the "…" indicator was never shown.
        applyInstrumentalGapIfNeeded(rows: displayRows, adjustedMs: adjustedMs)

        // While a long instrumental gap is active, show dots instead of the previous line.
        if instrumentalGapProgress != nil {
            newPrimary = nil
            newActive = []
        }

        let newKaraoke = Self.karaokeByteEnds(
            for: newActive,
            adjustedMs: adjustedMs,
            rows: displayRows
        )

        // Line selection, instrumental gaps and word fill share the filtered clock.
        karaokePlaybackMs = adjustedMs

        if newPrimary != currentLineIndex { currentLineIndex = newPrimary }
        if newActive != activeLineIndices { activeLineIndices = newActive }
        if newKaraoke != karaokeByteEnds { karaokeByteEnds = newKaraoke }
    }

    func clearLineHighlight() {
        currentLineIndex = nil
        activeLineIndices = []
        karaokeByteEnds = [:]
        karaokePlaybackMs = 0
    }

    nonisolated static func karaokeByteEnds(
        for indices: Set<Int>,
        adjustedMs: Int,
        rows: [LyricDisplayRow]
    ) -> [Int: Int] {
        guard !indices.isEmpty else { return [:] }
        var result: [Int: Int] = [:]
        for index in indices {
            guard rows.indices.contains(index) else { continue }
            if let byteEnd = LyricKaraokeTiming.activeByteEnd(
                in: rows[index].cueLine,
                adjustedMs: adjustedMs
            ) {
                result[index] = byteEnd
            }
        }
        return result
    }

    private func clearInstrumentalGap() {
        if instrumentalGapProgress != nil || instrumentalGapAfterIndex != nil {
            instrumentalGapProgress = nil
            instrumentalGapAfterIndex = nil
        }
    }

    /// Intro / bridge / outro only: show a filling "…" when the wait is an outlier vs this song’s normal spacing.
    private func applyInstrumentalGapIfNeeded(
        rows: [LyricDisplayRow],
        adjustedMs: Int
    ) {
        _ = rows
        let timed = instrumentalTimedLeads
        guard timed.count >= 2 else {
            clearInstrumentalGap()
            return
        }

        let typicalGap = instrumentalTypicalGapMs
        let outlierThreshold = max(
            Self.instrumentalGapAbsoluteFloorMs,
            Int(Double(typicalGap) * Self.instrumentalGapMedianMultiplier)
        )

        // Upper bound: word highlighting ticks frequently, even in long TTML documents.
        var low = 0
        var high = timed.count
        while low < high {
            let middle = low + (high - low) / 2
            if timed[middle].startMs <= adjustedMs { low = middle + 1 }
            else { high = middle }
        }
        let upcoming = low < timed.count ? timed[low] : nil
        let previous = low > 0 ? timed[low - 1] : nil

        let gapStart: Int
        let gapEnd: Int
        let afterIndex: Int?

        if let upcoming {
            // Intro (no previous yet) or mid-song bridge.
            if let previous {
                gapStart = previous.startMs
                afterIndex = previous.index
            } else {
                guard upcoming.startMs >= Self.instrumentalGapAbsoluteFloorMs else {
                    clearInstrumentalGap()
                    return
                }
                gapStart = 0
                afterIndex = nil
            }
            gapEnd = upcoming.startMs
        } else {
            // Outro / trailing instrumental: keep the last lyric — do not show "…" after the final line.
            clearInstrumentalGap()
            return
        }

        let gapLength = gapEnd - gapStart
        // Intro gaps only need to clear the absolute floor — the song's typical
        // line spacing hasn't been established yet.
        let minGap = (previous == nil) ? Self.instrumentalGapAbsoluteFloorMs : outlierThreshold
        guard gapLength >= minGap else {
            clearInstrumentalGap()
            return
        }

        // Respect an explicit TTML end. LRC only has line starts, so estimate a
        // conservative vocal duration from both phrase length and the interval. The
        // old fixed ~2.5 s hold changed to dots while the phrase was still being sung.
        let enterGapAt: Int
        if let previous,
           rows.indices.contains(previous.index) {
            let row = rows[previous.index]
            if row.preservesSourceTiming,
               let explicitEnd = row.endMs,
               explicitEnd > previous.startMs,
               explicitEnd < gapEnd {
                enterGapAt = explicitEnd
            } else {
                let visibleCharacterCount = row.text.unicodeScalars.reduce(into: 0) { count, scalar in
                    if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
                }
                let textEstimate = 1_200 + visibleCharacterCount * 180
                let proportionalEstimate = Int(Double(gapLength) * 0.55)
                let hold = min(
                    Self.instrumentalGapMaximumHoldMs,
                    max(Self.instrumentalGapMinimumHoldMs, max(textEstimate, proportionalEstimate))
                )
                enterGapAt = previous.startMs + hold
            }
        } else {
            enterGapAt = gapStart
        }
        guard gapEnd - enterGapAt >= Self.instrumentalGapMinimumVisibleMs else {
            clearInstrumentalGap()
            return
        }
        guard adjustedMs >= enterGapAt, adjustedMs < gapEnd else {
            clearInstrumentalGap()
            return
        }

        // Fill 0→1 from when "…" appears until the next lyric — do NOT hide early
        // when a few seconds remain (that left the dots stuck ~2/3 full).
        let fillLength = gapEnd - enterGapAt
        guard fillLength > 0 else {
            clearInstrumentalGap()
            return
        }
        let progress = min(1, max(0, Double(adjustedMs - enterGapAt) / Double(fillLength)))
        instrumentalGapAfterIndex = afterIndex
        if abs((instrumentalGapProgress ?? -1) - progress) > 0.005 {
            instrumentalGapProgress = progress
        } else if instrumentalGapProgress == nil {
            instrumentalGapProgress = progress
        }
    }

    func rebuildInstrumentalGapCache() {
        instrumentalTimedLeads = displayRows.enumerated().compactMap { index, row -> (Int, Int)? in
            guard let start = row.startMs else { return nil }
            let blank = row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !blank, !row.isSecondaryAgent else { return nil }
            return (index, start)
        }
        instrumentalTimedLeads.sort { $0.startMs == $1.startMs ? $0.index < $1.index : $0.startMs < $1.startMs }
        let starts = instrumentalTimedLeads.map(\.1)
        instrumentalTypicalGapMs = Self.medianPositiveGapMs(in: starts)
    }

    /// Median positive delta between consecutive timestamps — the song’s “normal” line spacing.
    nonisolated private static func medianPositiveGapMs(in starts: [Int]) -> Int {
        // `1..<sorted.count` traps when count == 0 (`1..<0`). Unsynced / notFound-adjacent
        // loads can seed rows with no timed leads — never build an inverted range.
        guard starts.count >= 2 else { return Self.instrumentalGapAbsoluteFloorMs }
        let sorted = starts.sorted()
        var gaps: [Int] = []
        gaps.reserveCapacity(sorted.count - 1)
        for index in 1..<sorted.count {
            let gap = sorted[index] - sorted[index - 1]
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return Self.instrumentalGapAbsoluteFloorMs }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    // MARK: Timer

    func synchronizeSeekClock(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let target = Int(max(0, seconds) * 1000)
        lastPositionSampleMs = target
        lastPositionSampleAt = CACurrentMediaTime()
        lastDisplayedPositionMs = target
        // Explicit seeks must bypass the <=120 ms jitter filter, including tiny backward ones.
        if case .loaded(let structured) = state {
            let offset = lyricDocument.map { LyricTime.milliseconds(fromSeconds: $0.lyricOffset) } ?? 0
            karaokePlaybackMs = target - structured.offset + offset
        }
        update(elapsedMs: target)
    }

    var isPlaying: Bool {

        playerState.playbackState == .playing
    }


    private var hasSyncedLyrics: Bool {
        followsPlayback
    }



    func setVisible(_ visible: Bool) {

        isShown = visible


        if !visible {

            resumeTask?.cancel()
            resumeTask = nil
            invalidateTranslationWork()
            resumeTranslationTask?.cancel()
            resumeTranslationTask = nil
            isUserScrolling = false
            prefersHiddenChrome = false

            stopTimer()

        } else {

            reconcileTracking()
        }
    }



    /// Forward scene-phase changes from the host view. Backgrounding must stop the
    /// tracking loop — the screen is off, so advancing lyrics/karaoke is wasted CPU.
    func setScenePhase(_ phase: ScenePhase) {
        let active = (phase == .active)
        guard active != isActive else { return }
        isActive = active
        reconcileTracking()
    }

    func reconcileTracking() {

        if isShown && isActive && isPlaying && followsPlayback {

            startTimer()

        } else {

            stopTimer()
            if !followsPlayback {
                clearLineHighlight()
                clearInstrumentalGap()
            }
        }
    }



    func startTimer() {
        // Always restart so a fresh track / resume after pause can't leave a dead task.
        stopTimer()
        let observedMs = lyricSeekTargetMs ?? Int((playerState.pendingSeekPosition ?? playerState.position) * 1000)
        lastPositionSampleMs = observedMs
        lastPositionSampleAt = CACurrentMediaTime()
        // After a seek the engine still reports the pre-seek position for a few ticks.
        // Accept forward progress only when it's close to our displayed time (real progress).
        let delta = observedMs - lastDisplayedPositionMs
        if !justSeeked, delta > 0, delta < 10_000 {
            lastDisplayedPositionMs = observedMs
        }
        justSeeked = false
        // On a new track / large forward jump, interpolatedElapsedMs() will catch up
        // via the monotonic-advance logic.  We do NOT accept backward jumps here.
        // Stay on the MainActor — Timer→Task hops queued behind SwiftUI and made paren cues feel late.
        // Word fill ticks at 30 Hz; line-only lyrics use 10 Hz. Re-read the budget each tick
        // so warm devices back off before thermal throttling starts.
        let karaokePlayback = hasKaraokePlayback
        trackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Keep the weak owner weak across suspension; a dismissed lyrics
                // screen must not be kept alive by its own tracking task.
                guard self?.performTrackingTick() == true else { return }
                let intervalNs = CassettePerformance.lyricsTickIntervalNs(karaokePlayback: karaokePlayback)
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    private func performTrackingTick() -> Bool {
        guard isShown, isActive, isPlaying, followsPlayback else { return false }
        update(elapsedMs: interpolatedElapsedMs())
        return true
    }

    /// Returns the best estimate of the current playback position in ms.
    /// Accepts forward progress unconditionally; only filters out backward
    /// jumps that are clearly stale pre-seek artifacts.
    func interpolatedElapsedMs() -> Int {
        if let target = lyricSeekTargetMs ?? playerState.pendingSeekPosition.map({ Int($0 * 1000) }) {
            // File parsers and AVPlayer can publish a stale clock during repositioning.
            // Never scroll back to it, or extrapolate vocals while a seek is still pending.
            lastPositionSampleMs = target
            lastPositionSampleAt = CACurrentMediaTime()
            lastDisplayedPositionMs = target
            return target
        }
        let nowMs = Int(playerState.position * 1000)
        let now = CACurrentMediaTime()

        if nowMs != lastPositionSampleMs {
            lastPositionSampleMs = nowMs
            lastPositionSampleAt = now
            // Fresh engine samples are authoritative. Ignore only tiny backward
            // quantization jitter; corrections larger than 120 ms commonly mean the
            // interpolated lyric clock advanced during buffering and must be pulled back.
            if nowMs >= lastDisplayedPositionMs || (lastDisplayedPositionMs - nowMs) > 120 {
                lastDisplayedPositionMs = nowMs
            }
            return lastDisplayedPositionMs
        }

        // No new sample — interpolate forward from the last known position.
        // The service samples at 500 ms. A frozen engine clock must not let
        // lyrics run seconds ahead and then jump backward when buffering ends.
        let interpolated = nowMs + min(750, max(0, Int((now - lastPositionSampleAt) * 1000)))
        lastDisplayedPositionMs = max(interpolated, lastDisplayedPositionMs)
        return lastDisplayedPositionMs
    }



    private func stopTimer() {
        trackingTask?.cancel()
        trackingTask = nil
    }
}
