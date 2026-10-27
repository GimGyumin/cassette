// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit
import OSLog

/// Suspends page-owned loading at departure, resumes it on a real return, and disables
/// touch handling on a page that has left its navigation stack. It never changes the
/// page's visibility: the SwiftUI zoom owns that surface for the whole transition.
struct AlbumPresentationLifecycle: UIViewControllerRepresentable {
    var pageID: String = ""
    var onDeparture: () -> Void = {}
    var onReturn: () async -> Void = {}
    func makeUIViewController(context: Context) -> AlbumPresentationController {
        let controller = AlbumPresentationController()
        controller.pageID = pageID
        controller.onDeparture = onDeparture
        controller.onReturn = onReturn
        return controller
    }
    func updateUIViewController(_ controller: AlbumPresentationController, context: Context) {
        controller.pageID = pageID
        controller.onDeparture = onDeparture
        controller.onReturn = onReturn
    }
}

final class AlbumPresentationController: UIViewController {
    var pageID: String = ""
    var onDeparture: () -> Void = {}
    var onReturn: () async -> Void = {}
    private let sessionID = String(UUID().uuidString.prefix(8))
    private var returnTask: Task<Void, Never>?
    private var appearanceRevision = 0
    private var isVisible = false
    private var departureCompletionPending = false
    /// Set once a transition has committed the page off the navigation stack. Late
    /// appearance callbacks after that point must never resume page-owned work even if
    /// the stack array updates a turn later.
    private var committedPop = false
    private weak var page: UIViewController?
    private weak var navigation: UINavigationController?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        appearanceRevision &+= 1
        isVisible = false
        departureCompletionPending = false
        returnTask?.cancel()
        captureNavigationPage()
        logPop("willDisappear")
        onDeparture()
        super.viewWillDisappear(animated)
        registerDepartureTransition()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captureNavigationPage()
        logPop("willAppear")
        // A late appearance callback from a page that already left the stack is what
        // re-presents a completed swipe-back. committedPop is intentionally permanent
        // for this controller: a complete pop must never resume or re-enable the page.
        guard !committedPop, !pageHasLeftNavigationStack else {
            disableInteractionIfPopped()
            return
        }
        enablePageInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureNavigationPage()
        logPop("didAppear")
        guard !committedPop, !pageHasLeftNavigationStack else {
            disableInteractionIfPopped()
            return
        }
        enablePageInteraction()
        isVisible = true
        // During an interactive cancellation, didAppear can arrive while the transition
        // is still settling. The departure completion owns the resume decision then.
        guard !departureCompletionPending else { return }
        resumeIfCurrent(revision: appearanceRevision)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        departureCompletionPending = false
        returnTask?.cancel()
        if !isPageInStack { committedPop = true }
        logPop("didDisappear")
        disableInteractionIfPopped()
    }

    /// Registers against the transition that is starting in `viewWillDisappear`.
    ///
    /// `isCancelled` at the completion is the authoritative difference between a
    /// cancelled edge-swipe (page stays) and a committed one (page is gone). Appearance
    /// callbacks alone cannot tell those apart while the transition is still settling.
    private func registerDepartureTransition() {
        guard let coordinator = transitionCoordinator ?? navigation?.transitionCoordinator else { return }
        let revision = appearanceRevision
        departureCompletionPending = true
        let registered = coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, appearanceRevision == revision else { return }
            departureCompletionPending = false
            Logger.ui.debug("[ALBUM-POP] transition-complete session=\(self.sessionID, privacy: .public) album=\(self.pageID, privacy: .public) cancelled=\(context.isCancelled, privacy: .public) inStack=\(self.isPageInStack, privacy: .public) window=\(self.page?.view.window != nil, privacy: .public)")
            if context.isCancelled {
                enablePageInteraction()
                // Resume here when the appearance already landed, otherwise didAppear
                // resumes once the cancelled swipe has fully settled.
                resumeIfCurrent(revision: revision)
            } else {
                // Push-over keeps the page in `navigation.viewControllers`; only a page
                // that actually left the stack is a committed pop.
                if !isPageInStack {
                    committedPop = true
                    returnTask?.cancel()
                } else {
                    // SwiftUI can commit the path removal one turn after the UIKit
                    // completion. Re-check once the stack has settled; a genuine
                    // push-over keeps the page in the array and is left alone.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isVisible, !self.isPageInStack else { return }
                        self.committedPop = true
                        self.returnTask?.cancel()
                        self.disableInteractionIfPopped()
                    }
                }
                disableInteractionIfPopped()
            }
        }
        if !registered { departureCompletionPending = false }

        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard let self, appearanceRevision == revision else { return }
            // Only a real edge-swipe owns this decision. A push, sheet or
            // fullScreenCover can share the coordinator but is not user-driven.
            guard context.initiallyInteractive, !context.isInteractive else { return }
            Logger.ui.debug("[ALBUM-POP] interaction-end session=\(self.sessionID, privacy: .public) album=\(self.pageID, privacy: .public) cancelled=\(context.isCancelled, privacy: .public) inStack=\(self.isPageInStack, privacy: .public)")
            if context.isCancelled {
                enablePageInteraction()
            } else {
                // The swipe-back was committed. Stop the outgoing page's controls from
                // accepting taps while the zoom settles; the next page is already
                // becoming visible underneath. If UIKit reports the cancellation late,
                // the appearance callbacks restore the returning page.
                disableOutgoingInteraction()
            }
        }
    }

    private func disableOutgoingInteraction() {
        guard let page else { return }
        page.view.isUserInteractionEnabled = false
    }

    /// Blocks touches from a page that has left the navigation stack. Visibility and
    /// layer removal are deliberately untouched: mutating them while the navigation
    /// transition is still rendering produces black frames, a full-screen rebound, or
    /// an abrupt disappearance. The transition owns that surface.
    private func disableInteractionIfPopped() {
        guard let page, let navigation else { return }
        guard !navigation.viewControllers.contains(where: { $0 === page }) else { return }
        page.view.isUserInteractionEnabled = false
        Logger.ui.debug("[ALBUM-POP] interaction-disabled session=\(self.sessionID, privacy: .public) album=\(self.pageID, privacy: .public) window=\(page.view.window != nil, privacy: .public)")
    }

    private func enablePageInteraction() {
        guard let page, !page.view.isUserInteractionEnabled else { return }
        page.view.isUserInteractionEnabled = true
        Logger.ui.debug("[ALBUM-POP] interaction-enabled session=\(self.sessionID, privacy: .public) album=\(self.pageID, privacy: .public) inStack=\(self.isPageInStack, privacy: .public)")
    }

    private var isPageInStack: Bool {
        guard let navigation else { return true }
        guard let page else { return false }
        return navigation.viewControllers.contains { $0 === page }
    }

    private func logPop(_ event: String) {
        Logger.ui.debug("[ALBUM-POP] \(event, privacy: .public) session=\(self.sessionID, privacy: .public) album=\(self.pageID, privacy: .public) inStack=\(self.isPageInStack, privacy: .public) top=\(self.isCurrentPage, privacy: .public) committed=\(self.committedPop, privacy: .public) window=\(self.page?.view.window != nil, privacy: .public)")
    }

    private var pageHasLeftNavigationStack: Bool {
        guard let navigation else { return false }
        guard let page else { return false }
        return !navigation.viewControllers.contains { $0 === page }
    }

    private func captureNavigationPage() {
        var candidate = parent
        while let controller = candidate {
            if let stack = controller.navigationController,
               controller.parent === stack || stack.viewControllers.contains(where: { $0 === controller }) {
                page = controller
                navigation = stack
                return
            }
            candidate = controller.parent
        }
    }

    private var isCurrentPage: Bool {
        guard let navigation else { return parent != nil }
        // A navigation stack exists, but the controller that owns it could not be
        // identified: treat the page as gone rather than resuming it after a pop.
        guard let page else { return false }
        return navigation.topViewController === page
    }

    private func resumeIfCurrent(revision: Int) {
        guard !committedPop, !pageHasLeftNavigationStack, isVisible, isCurrentPage,
              appearanceRevision == revision else { return }
        returnTask?.cancel()
        returnTask = Task { [weak self] in
            guard !Task.isCancelled, let self, !committedPop, isVisible,
                  !pageHasLeftNavigationStack, isCurrentPage,
                  appearanceRevision == revision else { return }
            await onReturn()
        }
    }
}
#endif
