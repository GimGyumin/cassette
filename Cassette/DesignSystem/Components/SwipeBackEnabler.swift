// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import SwiftUI
import UIKit

/// Pages whose edge swipe the system delegate refuses need this bridge, not just pages that hide the
/// system back button: a detail page reached *from another pushed page* runs under a delegate that
/// only vouches for the pop it was installed for, so the swipe that should leave the pushed page
/// does nothing. The bridge owns the recognizer delegate while the page is visible (vetting the
/// gesture itself: stack depth > 1, no transition in flight) and restores the previous delegate
/// before another destination appears.
private final class SwipeBackHostingController: UIViewController, UIGestureRecognizerDelegate {
    private weak var popGesture: UIGestureRecognizer?
    private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
    private var isVisible = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        armSwipeBack()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        restoreDelegate()
        super.viewWillDisappear(animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { restoreDelegate() }
    }

    fileprivate func armSwipeBack() {
        guard isVisible, viewIfLoaded?.window != nil,
              let navigation = resolvedNavigationController(),
              navigation.viewControllers.count > 1,
              let gesture = navigation.interactivePopGestureRecognizer else { return }
        if popGesture !== gesture { restoreDelegate() }
        if gesture.delegate !== self {
            previousDelegate = gesture.delegate
            popGesture = gesture
            gesture.delegate = self
        }
        gesture.isEnabled = true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isVisible, let navigation = resolvedNavigationController() else { return false }
        // Starting a second pop during a push/pop can wedge UIKit and SwiftUI's paths.
        return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
    }

    private func restoreDelegate() {
        if let gesture = popGesture, gesture.delegate === self {
            gesture.delegate = previousDelegate
        }
        popGesture = nil
        previousDelegate = nil
    }

    private func resolvedNavigationController() -> UINavigationController? {
        if let navigationController { return navigationController }
        var ancestor = parent
        while let current = ancestor {
            if let navigation = current as? UINavigationController { return navigation }
            if let navigation = current.navigationController { return navigation }
            ancestor = current.parent
        }
        return nil
    }
}

private struct SwipeBackEnablerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackHostingController {
        SwipeBackHostingController()
    }

    func updateUIViewController(_ uiViewController: SwipeBackHostingController, context: Context) {
        uiViewController.armSwipeBack()
    }
}

extension View {
    /// Arms the interactive pop gesture for a page the system delegate would refuse to pop.
    ///
    /// - Parameter enabled: pass `false` for a page whose pop gesture must stay owned by SwiftUI —
    ///   a zoom destination (`navigationTransition(.zoom(…)`), where the delegate drives the zoom
    ///   dismissal itself.
    @ViewBuilder
    func enableSwipeBack(_ enabled: Bool = true) -> some View {
        if enabled {
            background(SwipeBackEnablerRepresentable())
        } else {
            self
        }
    }
}
#endif
