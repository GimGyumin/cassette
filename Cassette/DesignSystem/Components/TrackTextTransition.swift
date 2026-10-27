// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Direction of a confirmed track change. The player title group slides in the
/// direction the queue moved; unknown changes use a neutral crossfade.
enum TrackTransitionDirection: Equatable {
    case forward
    case backward
    case fade

    var transition: AnyTransition {
        switch self {
        case .forward:
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        case .fade:
            .opacity
        }
    }
}

/// The queue position is part of the identity: the same song can appear twice.
struct TrackSnapshotKey: Equatable {
    let trackID: String?
    let index: Int
    let queueCount: Int
    let firstTrackID: String?

    /// Identity for the rendered title group. Queue edits and same-song index
    /// changes keep the same id so they do not replay the title transition.
    var contentID: String {
        "\(trackID ?? "nil")|\(index)"
    }

    @MainActor
    init(playerState: PlayerState) {
        trackID = playerState.currentTrack?.id
        index = playerState.currentIndex
        queueCount = playerState.queue.count
        firstTrackID = playerState.queue.first?.id
    }

    init(trackID: String?, index: Int, queueCount: Int, firstTrackID: String?) {
        self.trackID = trackID
        self.index = index
        self.queueCount = queueCount
        self.firstTrackID = firstTrackID
    }

    /// Only a different song should animate. A queue reorder can move the
    /// currently playing song to another index, and duplicate entries share the
    /// same title, so index-only changes would animate the same text.
    static func isTrackChange(from old: TrackSnapshotKey, to new: TrackSnapshotKey) -> Bool {
        old.trackID != new.trackID
    }

    static func direction(
        from old: TrackSnapshotKey,
        to new: TrackSnapshotKey,
        repeatAll: Bool
    ) -> TrackTransitionDirection {
        let sameQueue = old.queueCount == new.queueCount && old.firstTrackID == new.firstTrackID
        guard sameQueue else { return .fade }
        if new.index > old.index {
            // repeat-all wraps from the first queue item back to the last; it is
            // a backward action even though the index goes up.
            if repeatAll, old.index == 0, new.index == old.queueCount - 1 { return .backward }
            return .forward
        }
        if new.index < old.index {
            // repeat-all wraps from the final queue item to the first; it is a
            // forward action even though the index goes down.
            if repeatAll, old.index == old.queueCount - 1, new.index == 0 { return .forward }
            return .backward
        }
        return .fade
    }
}

/// Wraps the title/artist group (not the artwork or transport controls) with:
/// - direction-aware slide/fade on track changes,
/// - interactive horizontal drag with spring-back,
/// - marquee pausing through an environment flag,
/// - one light haptic only on a confirmed change.
struct TrackTextSwipeTransition: ViewModifier {
    let playerState: PlayerState
    let enabled: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    var commitDistance: CGFloat = 55
    var predictedDistance: CGFloat = 110
    var maxOffset: CGFloat = 120
    var resistance: CGFloat = 0.6

    @Environment(\.marqueePaused) private var parentMarqueePaused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedSnapshot: TrackSnapshotKey?
    @State private var displayedID = ""
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isTransitioning = false
    @State private var transitionTask: Task<Void, Never>?

    private var snapshotKey: TrackSnapshotKey {
        TrackSnapshotKey(playerState: playerState)
    }

    /// The snapshot currently rendered is intentionally one step behind: the
    /// body that changes the content id can then pick the correct slide edge,
    /// and `onChange` catches it up afterwards.
    private var isTrackChangePending: Bool {
        guard let displayedSnapshot else { return false }
        return TrackSnapshotKey.isTrackChange(from: displayedSnapshot, to: snapshotKey)
    }

    private var resolvedDirection: TrackTransitionDirection {
        guard !reduceMotion, let displayedSnapshot else { return .fade }
        guard TrackSnapshotKey.isTrackChange(from: displayedSnapshot, to: snapshotKey) else {
            return .fade
        }
        return TrackSnapshotKey.direction(
            from: displayedSnapshot,
            to: snapshotKey,
            repeatAll: playerState.repeatMode == .all
        )
    }

    /// Queue-only edits keep the old id, so they never replay the transition.
    private var contentID: String {
        if isTrackChangePending { return snapshotKey.contentID }
        return displayedID.isEmpty ? snapshotKey.contentID : displayedID
    }

    private var resolvedTransition: AnyTransition {
        reduceMotion ? .opacity : resolvedDirection.transition
    }

    /// One stable curve for every direction: the displayed snapshot updates
    /// immediately after the change, and a direction-dependent curve could
    /// retarget an in-flight transition.
    private var resolvedAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.22)
            : .spring(response: 0.34, dampingFraction: 0.92)
    }

    private var settleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.88)
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            content
                .id(contentID)
                .transition(resolvedTransition)
                .offset(x: dragOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .animation(resolvedAnimation, value: contentID)
        .environment(\.marqueePaused, parentMarqueePaused || isDragging || isTransitioning)
        .allowsHitTesting(!isTransitioning)
        // Simultaneous so the mini-player's parent tap-to-open and the full
        // player's vertical sheet dismiss keep working; this gesture only
        // claims clearly horizontal movement.
        .simultaneousGesture(swipeGesture)
        .onAppear(perform: seedDisplayedSnapshot)
        .onChange(of: snapshotKey) { old, new in
            handleSnapshotChange(from: old, to: new)
        }
        .onDisappear {
            transitionTask?.cancel()
        }
        .accessibilityAction(named: Text(String(localized: "Next Track", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))) {
            guard enabled else { return }
            onNext()
        }
        .accessibilityAction(named: Text(String(localized: "Previous Track", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))) {
            guard enabled else { return }
            onPrevious()
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard enabled, !isTransitioning, playerState.currentTrack != nil else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                isDragging = true
                dragOffset = max(-maxOffset, min(maxOffset, value.translation.width * resistance))
            }
            .onEnded { value in
                guard isDragging else { return }
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let next = horizontal < -commitDistance || predicted < -predictedDistance
                let previous = horizontal > commitDistance || predicted > predictedDistance
                isDragging = false

                guard next || previous else {
                    withAnimation(settleAnimation) {
                        dragOffset = 0
                    }
                    return
                }

                HapticFeedback.light.trigger()
                withAnimation(settleAnimation) {
                    dragOffset = 0
                }
                if next {
                    onNext()
                } else {
                    onPrevious()
                }
            }
    }

    private func seedDisplayedSnapshot() {
        let current = snapshotKey
        if displayedSnapshot == nil { displayedSnapshot = current }
        if displayedID.isEmpty { displayedID = current.contentID }
    }

    private func handleSnapshotChange(from old: TrackSnapshotKey, to new: TrackSnapshotKey) {
        let changed: Bool
        if let displayedSnapshot {
            changed = TrackSnapshotKey.isTrackChange(from: displayedSnapshot, to: new)
        } else {
            changed = TrackSnapshotKey.isTrackChange(from: old, to: new)
        }

        if changed {
            // Keep the new id after the displayed snapshot catches up, so the
            // transition doesn't collapse back to the outgoing view's id.
            displayedID = new.contentID
            applyTrackChange()
        }
        displayedSnapshot = new
    }

    private func applyTrackChange() {
        dragOffset = 0
        isDragging = false
        transitionTask?.cancel()
        isTransitioning = true
        // The new title's marquee sees this state and waits until the slide ends.
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            isTransitioning = false
        }
    }
}

