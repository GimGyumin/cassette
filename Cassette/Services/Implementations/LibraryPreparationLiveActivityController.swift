// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import OSLog

#if os(iOS)
import ActivityKit
#endif

/// Owns the Live Activity lifecycle for the library-preparation pass.
///
/// Started when a pass begins — which is exactly when the app puts `LibraryPreparationView` on
/// screen, so the activity tracks something the user is watching — updated as progress moves, and
/// ended when the pass finishes or fails. It never drives the pass itself: the preparation service
/// reports progress and this renders it.
///
/// The whole ActivityKit path is inside `#if os(iOS)`: macOS has no Live Activities, so the macOS
/// build compiles this file down to nothing and cannot verify it.
@MainActor
@Observable
final class LibraryPreparationLiveActivityController {

    /// Honours the user's choice to keep the lock screen clean.
    var isEnabled = true
    var artworkProvider: (@MainActor (String) async -> PreparationArtworkStore.Asset?)?
    private var estimator = PreparationETA()

    /// ActivityKit may only **start** an activity while the app is in the foreground; a background
    /// pass may only *update* one it did not start. Injected so the Services layer stays UIKit-free.
    var isAppActive: @MainActor () -> Bool = { true }

    /// True while an activity is on screen. The preparation pass uses this to skip bridging artwork
    /// that would never be displayed.
    var isPresenting: Bool {
        #if os(iOS)
        activity != nil
        #else
        false
        #endif
    }

    #if os(iOS)
    private var activity: Activity<LibraryPreparationActivityAttributes>?
    private var lastPushedAt = Date.distantPast
    /// ActivityKit budgets updates; a cover pass can move several times a second, so intermediate
    /// progress is coalesced. Terminal states are always pushed.
    private let minimumUpdateInterval: TimeInterval = 5
    private var lastPushedState: LibraryPreparationActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    #endif

    /// Reuses an interrupted pass's activity and removes duplicate activities after relaunch.
    func reconcileOnLaunch() {
        #if os(iOS)
        let existing = Activity<LibraryPreparationActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        activity = existing.first
        for stale in existing.dropFirst() {
            Logger.library.notice("[LIVE-ACTIVITY] ending stale activity \(stale.id, privacy: .public)")
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        #endif
    }

    /// Reports progress. `phaseTitle` must already be localized — the widget extension has no string
    /// catalogue of its own.
    func update(
        with progress: LibraryPreparationProgress,
        phaseTitle: String,
        serverName: String
    ) {
        #if os(iOS)
        // Every rejection below is logged: "the activity just doesn't appear" is otherwise
        // impossible to diagnose from a device log.
        guard isEnabled else {
            Logger.library.debug("[LIVE-ACTIVITY] skipped: disabled by the user")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Logger.library.debug("[LIVE-ACTIVITY] skipped: Live Activities are off for Cassette")
            return
        }

        let isFinished = progress.phase == .complete || progress.phase == .failed
        guard progress.phase != .idle else {
            end(dismissImmediately: true)
            return
        }

        var state = LibraryPreparationActivityAttributes.state(
            from: progress,
            title: phaseTitle,
            isFinished: isFinished,
            failed: progress.phase == .failed
        )

        state.estimatedCompletion = estimator.estimate(progress)
        state.etaTitle = String(localized: "Estimated phase completion", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)

        // `.checking` only probes the server and usually finds nothing to do, so starting an activity
        // for it would flash the lock screen on every launch. Only real work starts one.
        let isRealWork = progress.phase.isPreparing

        if let activity {
            let now = Date()
            guard state != lastPushedState else { return }
            let phaseChanged = state.phase != lastPushedState?.phase
            guard isFinished || phaseChanged || now.timeIntervalSince(lastPushedAt) >= minimumUpdateInterval else { return }
            lastPushedAt = now
            lastPushedState = state
            if isFinished {
                // One task so the final frame is pushed before the activity is dismissed.
                self.activity = nil
                let previous = updateTask
                updateTask = Task {
                    await previous?.value
                    let rendered = await prepareArtwork(state, coverID: progress.activeCoverArtId, activityID: activity.id)
                    await activity.update(ActivityContent(state: rendered, staleDate: nil))
                    await activity.end(
                        ActivityContent(state: rendered, staleDate: nil),
                        dismissalPolicy: .after(.now + 4)
                    )
                }
            } else {
                let previous = updateTask
                updateTask = Task {
                    await previous?.value
                    let rendered = await prepareArtwork(state, coverID: progress.activeCoverArtId, activityID: activity.id)
                    await activity.update(ActivityContent(state: rendered, staleDate: nil))
                }
            }
            return
        }

        // Nothing to start for a pass that is already over, or for the launch-time probe.
        guard !isFinished, isRealWork else {
            Logger.library.debug("[LIVE-ACTIVITY] not started: phase \(progress.phase.rawValue, privacy: .public)")
            return
        }
        // Apple: `Activity.request` only works while the app is in the foreground. A pass that starts
        // inside a background window can only update an activity that already exists.
        guard isAppActive() else {
            Logger.library.info("[LIVE-ACTIVITY] not started: app is not in the foreground")
            return
        }
        do {
            activity = try Activity.request(
                attributes: LibraryPreparationActivityAttributes(serverName: serverName),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastPushedAt = Date()
            lastPushedState = state
            Logger.library.info("[LIVE-ACTIVITY] started for '\(serverName, privacy: .public)'")
        } catch {
            Logger.library.debug("[LIVE-ACTIVITY] could not start: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    #if os(iOS)
    private func prepareArtwork(_ state: LibraryPreparationActivityAttributes.ContentState, coverID: String?, activityID: String) async -> LibraryPreparationActivityAttributes.ContentState {
        var result = state
        if let coverID, let asset = await artworkProvider?(coverID) {
            result.activeCoverArtId = asset.id
            result.backgroundRGB = asset.backgroundRGB
        } else {
            result.activeCoverArtId = lastArtworkActivityID == activityID ? lastArtwork?.id : nil
            result.backgroundRGB = lastArtworkActivityID == activityID ? lastArtwork?.backgroundRGB : nil
        }
        if let id = result.activeCoverArtId {
            lastArtworkActivityID = activityID
            lastArtwork = PreparationArtworkStore.Asset(id: id, backgroundRGB: result.backgroundRGB)
        }
        return result
    }
    private var lastArtwork: PreparationArtworkStore.Asset?
    private var lastArtworkActivityID: String?
    #endif

    /// Removes the activity — used when a pass is cancelled or the user turns the feature off.
    func end(dismissImmediately: Bool = false) {
        estimator = PreparationETA()
        #if os(iOS)
        guard let activity else { return }
        self.activity = nil
        lastArtwork = nil
        lastPushedState = nil
        let dismissal: ActivityUIDismissalPolicy = dismissImmediately ? .immediate : .after(.now + 4)
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: dismissal)
        }
        Logger.library.info("[LIVE-ACTIVITY] ended (immediate=\(dismissImmediately, privacy: .public))")
        #endif
    }
}
