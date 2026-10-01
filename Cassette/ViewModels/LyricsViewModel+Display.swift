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
    func speakerSide(at index: Int) -> LyricSpeakerSide {
        guard displayRows.indices.contains(index) else { return .leading }
        return displayRows[index].speakerSide
    }

    func isSecondaryAgent(at index: Int) -> Bool {
        guard displayRows.indices.contains(index) else { return false }
        return displayRows[index].isSecondaryAgent
    }

    func cueLine(at index: Int) -> CueLine? {
        guard displayRows.indices.contains(index) else { return nil }
        return displayRows[index].cueLine
    }

    func displayWords(at index: Int) -> [LyricDisplayWord] {
        guard displayRows.indices.contains(index) else { return [] }
        return displayRows[index].words
    }

    /// Background (x-bg) display words for the chorus row — used for
    /// word-by-word karaoke highlighting in the chorus flow block.
    func displayBackgroundWords(at index: Int) -> [LyricDisplayWord] {
        guard displayRows.indices.contains(index) else { return [] }
        return displayRows[index].backgroundWords
    }

    func pronunciationWords(at index: Int, background: Bool = false) -> [LyricDisplayWord] {
        guard pronunciationRows.indices.contains(index) else { return [] }
        return pronunciationRows[index].filter { $0.isBackground == background }
    }

    /// Next chronologically-timed visible lyric start after this row.
    /// Used so the last karaoke word can keep filling until the following lyric arrives.
    func nextLyricStartMs(after index: Int) -> Int? {
        guard displayRows.indices.contains(index),
              let currentStart = displayRows[index].startMs else { return nil }
        guard index + 1 < displayRows.count else { return nil }
        for candidate in displayRows[(index + 1)...] {
            guard let start = candidate.startMs else { continue }
            let blank = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !blank, start >= currentStart else { continue }
            return start
        }
        return nil
    }

    /// Secondary / echo stacked under the focused lead only — never duet partners (vocal2).
    func activeBackingOverlayIndices(underLead leadIndex: Int) -> [Int] {
        guard displayRows.indices.contains(leadIndex),
              activeLineIndices.contains(leadIndex),
              currentLineIndex == leadIndex else { return [] }
        return activeLineIndices
            .filter { $0 != leadIndex }
            .filter { shouldStackUnderLead($0, primary: leadIndex) }
            .sorted()
    }

    /// Hide rows that are rendered as underlay under the focused lead.
    /// Backing that outlives its lead stays visible as its own smaller active row
    /// (Apple Music independent line lifecycle) while scroll follows the newest lead.
    func shouldHideStandaloneBacking(at index: Int) -> Bool {
        guard let primary = currentLineIndex, primary != index else { return false }
        guard activeLineIndices.contains(index) else { return false }
        return shouldStackUnderLead(index, primary: primary)
    }

    /// Stack under the current lead only while this part still “belongs” to that phrase.
    private func shouldStackUnderLead(_ index: Int, primary: Int) -> Bool {
        guard shouldRenderAsUnderLead(index, primary: primary) else { return false }
        if isSecondaryAgent(at: index) {
            return belongsWithCurrentLead(index, primary: primary)
        }
        return true
    }

    /// Backing started in/near this lead’s window → underlay; otherwise keep as own row.
    private func belongsWithCurrentLead(_ index: Int, primary: Int) -> Bool {
        guard displayRows.indices.contains(index),
              displayRows.indices.contains(primary) else { return false }
        let bg = displayRows[index]
        let lead = displayRows[primary]
        guard let leadStart = lead.startMs,
              let bgStart = bg.startMs else { return bg.isSecondaryAgent }
        let leadEnd = lead.endMs
            ?? lead.cueLine?.end
            ?? lead.cueLine?.cue.compactMap(\.end).max()
            ?? leadStart
        return bgStart >= leadStart - 500 && bgStart <= leadEnd + 600
    }

    /// Apple Music rules:
    /// - `ttm:role=background` / chorus → small under lead (while belonging to that phrase)
    /// - different `ttm:agent` duet partners → full-size L/R, never underlay
    /// - same-agent identical overlap → echo underlay
    private func shouldRenderAsUnderLead(_ index: Int, primary: Int) -> Bool {
        guard displayRows.indices.contains(index),
              displayRows.indices.contains(primary) else { return false }
        let row = displayRows[index]
        let lead = displayRows[primary]

        let rowAgent = row.agentId ?? row.cueLine?.agentId
        let leadAgent = lead.agentId ?? lead.cueLine?.agentId
        // Distinct vocal agents are always full-size duet partners.
        if let rowAgent, let leadAgent, rowAgent != leadAgent {
            return false
        }

        if row.speakerSide != lead.speakerSide {
            return false
        }

        if row.isSecondaryAgent {
            return true
        }

        // Same agent + identical text + near-simultaneous = echo underlay.
        guard let rowAgent, let leadAgent, rowAgent == leadAgent else { return false }
        let a = Self.normalizedLyricText(row.text)
        let b = Self.normalizedLyricText(lead.text)
        guard !a.isEmpty, a == b else { return false }
        guard let primaryStart = lead.startMs,
              let otherStart = row.startMs else { return false }
        return abs(otherStart - primaryStart) <= Self.simultaneousLineThresholdMs * 4
    }

    nonisolated private static func normalizedLyricText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // MARK: Seek

    func userTapped(lineIndex: Int) {

        guard case .loaded(let structured) = state,
              Self.hasUsableTiming(structured),
              displayRows.indices.contains(lineIndex),
              let start = displayRows[lineIndex].startMs
        else {
            return
        }


        let seconds =
        TimeInterval(start + structured.offset) / 1000

        // Reset scrolling state so auto-scroll resumes immediately after seek.
        resumeTask?.cancel()
        resumeTask = nil
        isUserScrolling = false
        prefersHiddenChrome = false
        // Store the tapped index so the view can scroll to it unconditionally after seek.
        pendingSeekScrollIndex = lineIndex
        scrollRestoreToken += 1
        justSeeked = true

        Task {
            // Await seek completion so the audio engine finishes repositioning
            // before we force-update lyric timing.
            await playerService.seek(to: seconds)

            // Force-inject the target time into the interpolation state.
            // Without this, interpolatedElapsedMs() may briefly drift back to
            // the pre-seek position while the audio session stabilizes, causing
            // karaoke progress to freeze or flicker.
            let targetMs = Int(seconds * 1000)
            lastPositionSampleMs = targetMs
            lastPositionSampleAt = CACurrentMediaTime()
            lastDisplayedPositionMs = targetMs

            // Immediately re-evaluate active lyric lines / words at the new position
            // so the UI jumps to the tapped line without waiting for the next timer tick.
            update(elapsedMs: targetMs)

            // Only restart tracking when audio is actually playing.
            // `isPlaying` is the definitive guard — without it the
            // interpolation loop advances lyrics while the transport
            // is paused (Bug: "tap lyric while paused → lyrics play alone").
            reconcileTracking()
        }
    }



    // MARK: Scroll

    func userStartedScrolling() {
        isUserScrolling = true
        scheduleScrollIdleResume()
    }

    /// Driven by lyrics `ScrollView` geometry. Scrolling is interaction, so it must keep
    /// player chrome visible; FullPlayerView may hide it only after idle + a lyric advance.
    func userScrolledLyrics(from _: CGFloat, to _: CGFloat) {
        if prefersHiddenChrome { prefersHiddenChrome = false }
        userStartedScrolling()
    }

    func userStoppedScrolling() {
        // Drag ended — idle-resume timer was already scheduled by userStartedScrolling.
        // No extra work needed here.
    }

    private func scheduleScrollIdleResume() {
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: .seconds(Self.scrollIdleSeconds))
            guard !Task.isCancelled else { return }
            self.isUserScrolling = false
        }
    }



    // MARK: Language

    func selectLanguage(_ lang: String) async {

        guard selectedLanguage != lang else {
            return
        }


        selectedLanguage = lang
        clearLineHighlight()

        await applyCurrentLanguage()
    }
}
