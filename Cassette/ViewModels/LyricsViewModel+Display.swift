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
        // Background singers appear only during their own timed phrase. Browsing
        // untimed lyrics still shows the complete text.
        if followsPlayback, isSecondaryAgent(at: index), !activeLineIndices.contains(index) { return true }
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


        let seconds = max(0, TimeInterval(start + structured.offset) / 1000
            - (lyricDocument?.lyricOffset ?? 0))
        let targetMs = Int(seconds * 1000)
        lyricSeekGeneration &+= 1
        let generation = lyricSeekGeneration
        let trackID = playerState.currentTrack?.id
        lyricSeekTask?.cancel()
        lyricSeekTargetMs = targetMs

        resumeTask?.cancel()
        resumeTask = nil
        isUserScrolling = false
        prefersHiddenChrome = false
        pendingSeekScrollIndex = lineIndex
        justSeeked = true
        amllForceSeek = true
        // Scroll/highlight immediately, independently of local decode or network latency.
        synchronizeSeekClock(to: seconds)
        scrollRestoreToken += 1

        let playerService = playerService
        lyricSeekTask = Task { [weak self] in
            await playerService.seek(to: seconds)
            guard !Task.isCancelled, let self,
                  lyricSeekGeneration == generation, playerState.currentTrack?.id == trackID else { return }
            lyricSeekTask = nil
            lyricSeekTargetMs = nil
            // The shared pending target keeps timing pinned until the engine actually lands.
            reconcileTracking()
        }
    }



    // MARK: Scroll

    func userStartedScrolling() {
        isUserScrolling = true
        scheduleScrollIdleResume()
    }

    /// Driven by lyrics `ScrollView` geometry. Scrolling is interaction, so it must keep
    /// player chrome visible; FullPlayerView may hide it only after the inactivity timeout.
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
