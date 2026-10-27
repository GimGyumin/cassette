#if os(iOS)
import Testing
import UIKit
import SwiftUI
@testable import Cassette

@Suite("Album presentation lifecycle")
@MainActor
struct AlbumZoomDismissalTests {
    @Test func cancelledSwipeWaitsForSettlingBeforeResuming() async {
        let page = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: page)
        let observer = AlbumPresentationController()
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        var returns = 0
        observer.onReturn = { returns += 1 }
        // UIKit supplies the transition coordinator before willDisappear when the
        // edge swipe starts; the cancellation result only arrives at its completion.
        let transition = AlbumTestTransitionCoordinator()
        transition.isCancelled = true
        navigation.suppliedCoordinator = transition
        observer.viewWillDisappear(true)
        observer.viewWillAppear(true)
        observer.viewDidAppear(true)
        await nextMainTurn()
        #expect(returns == 0)
        #expect(!page.view.isHidden)
        transition.finish()
        await nextMainTurn()
        #expect(returns == 1)
    }

    @Test func committedSwipeDisablesThePoppedPageAndBlocksLateReturn() async {
        let root = UIViewController(), page = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        let observer = AlbumPresentationController()
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        var returns = 0
        observer.onReturn = { returns += 1 }
        observer.viewWillAppear(false)
        observer.viewDidAppear(false)
        // Departure wins even if the initial resume task was already queued.
        let transition = AlbumTestTransitionCoordinator()
        navigation.suppliedCoordinator = transition
        observer.viewWillDisappear(true)
        navigation.popViewController(animated: false)
        observer.viewDidDisappear(true)
        transition.finish()
        await nextMainTurn()
        #expect(returns == 0)
        // The removed page must not accept taps after the visual dismissal, but the
        // lifecycle must never alter its visibility or the zoom's render surface.
        #expect(!page.view.isUserInteractionEnabled)
        #expect(!page.view.isHidden)

        // Late SwiftUI teardown callbacks cannot resume loading or re-enable touches.
        observer.viewWillAppear(true)
        observer.viewDidAppear(true)
        await nextMainTurn()
        #expect(returns == 0)
        #expect(!page.view.isUserInteractionEnabled)
        #expect(!page.view.isHidden)
    }

    @Test func committedSwipeDisablesTheOutgoingPageBeforeTheZoomSettles() async {
        let page = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: page)
        let observer = AlbumPresentationController()
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        observer.viewWillAppear(false)
        observer.viewDidAppear(false)
        let transition = AlbumTestTransitionCoordinator()
        navigation.suppliedCoordinator = transition
        observer.viewWillDisappear(true)
        // The user released past the commit threshold. The page is visibly leaving,
        // so taps on its play button must not start playback. Visibility is retired
        // only once the zoom has finished.
        transition.endInteraction(isCancelled: false)
        #expect(!page.view.isUserInteractionEnabled)
        #expect(!page.view.isHidden)

        // UIKit can finalize a cancellation after the interaction ended; the returning
        // page must be tappable again.
        transition.endInteraction(isCancelled: true)
        #expect(page.view.isUserInteractionEnabled)
        #expect(!page.view.isHidden)
    }

    @Test func pushOverKeepsThePageAliveForItsReturn() async {
        let root = UIViewController(), page = UIViewController(), artist = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        let observer = AlbumPresentationController()
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        var returns = 0
        observer.onReturn = { returns += 1 }
        observer.viewWillAppear(false)
        observer.viewDidAppear(false)
        await nextMainTurn()
        returns = 0

        // Album → artist: the album stays in the stack under the new page and must not
        // be retired, or coming back would leave it hidden and untappable.
        let transition = AlbumTestTransitionCoordinator()
        navigation.suppliedCoordinator = transition
        observer.viewWillDisappear(true)
        navigation.pushViewController(artist, animated: false)
        observer.viewDidDisappear(true)
        transition.finish()
        await nextMainTurn()
        #expect(!page.view.isHidden)
        #expect(page.view.isUserInteractionEnabled)

        navigation.popViewController(animated: false)
        observer.viewWillAppear(true)
        observer.viewDidAppear(true)
        await nextMainTurn()
        #expect(returns == 1)
        #expect(!page.view.isHidden)
        #expect(page.view.isUserInteractionEnabled)
    }

    @Test func chromeReleaseWaitsForTheCoordinatorCapturedAtSwipeStart() async {
        let appearance = ChromeAppearance()
        let owner = UUID()
        let page = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: page)
        let observer = ChromeAppearanceController(appearance: appearance, ownerID: owner, scheme: .dark)
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        observer.viewDidAppear(false)
        await nextMainTurn()
        #expect(appearance.overrideColorScheme == .dark)
        let transition = AlbumTestTransitionCoordinator()
        navigation.suppliedCoordinator = transition
        observer.viewWillDisappear(true)
        navigation.suppliedCoordinator = nil
        observer.viewDidDisappear(true)
        await nextMainTurn()
        #expect(appearance.overrideColorScheme == .dark)
        transition.finish()
        await nextMainTurn()
        #expect(appearance.overrideColorScheme == nil)
    }

    @Test func poppedPageCannotReclaimChromeFromALateAppearance() async {
        let appearance = ChromeAppearance()
        let root = UIViewController(), page = UIViewController()
        let navigation = AlbumTestNavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        let observer = ChromeAppearanceController(appearance: appearance, ownerID: UUID(), scheme: .dark)
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        observer.viewDidAppear(false)
        await nextMainTurn()
        #expect(appearance.overrideColorScheme == .dark)
        observer.viewWillDisappear(true)
        navigation.popViewController(animated: false)
        observer.viewDidDisappear(true)
        await nextMainTurn()
        observer.viewDidAppear(true)
        await nextMainTurn()
        #expect(appearance.overrideColorScheme == nil)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func cancelledReturnKeepsHostingViewVisibleAndPoppedPageInteractionDisabled() async {
        let root = UIViewController(), page = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        page.loadViewIfNeeded()
        let observer = AlbumPresentationController()
        page.addChild(observer)
        page.view.addSubview(observer.view)
        observer.didMove(toParent: page)
        var departures = 0, returns = 0
        observer.onDeparture = { departures += 1 }
        observer.onReturn = { returns += 1 }

        observer.viewWillDisappear(true)
        #expect(departures == 1)
        #expect(!page.view.isHidden)
        // UIKit's appearance callback also covers a cancelled interactive back gesture.
        observer.viewDidAppear(true)
        for _ in 0..<10 where returns == 0 { await Task.yield() }
        #expect(returns == 1)
        #expect(!page.view.isHidden)
        #expect(page.view.isUserInteractionEnabled)

        observer.viewWillDisappear(true)
        navigation.popToRootViewController(animated: false)
        observer.viewDidDisappear(true)
        #expect(departures == 2)
        // The page left the stack: its controls must not accept taps, but the
        // lifecycle leaves visibility to SwiftUI so the zoom cannot be blanked out.
        #expect(!page.view.isUserInteractionEnabled)
        #expect(!page.view.isHidden)
        #expect(!root.view.isHidden)
    }
}

@MainActor
private final class AlbumTestNavigationController: UINavigationController {
    var suppliedCoordinator: (any UIViewControllerTransitionCoordinator)?
    override var transitionCoordinator: (any UIViewControllerTransitionCoordinator)? { suppliedCoordinator }
}

@MainActor
private final class AlbumTestTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    var isAnimated = true
    var presentationStyle: UIModalPresentationStyle = .none
    var initiallyInteractive = true
    var isInterruptible = true
    var isInteractive = false
    var isCancelled = false
    var transitionDuration: TimeInterval = 0.3
    var percentComplete: CGFloat = 0.8
    var completionVelocity: CGFloat = 1
    var completionCurve: UIView.AnimationCurve = .easeInOut
    var containerView = UIView()
    var targetTransform = CGAffineTransform.identity
    private var completions: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    private var interactionHandlers: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }
    func animate(alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        animation?(self)
        if let completion { completions.append(completion) }
        return true
    }
    func animateAlongsideTransition(in view: UIView?, animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }
    func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {
        interactionHandlers.append(handler)
    }
    func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {
        interactionHandlers.append(handler)
    }
    /// Simulates the user releasing the edge-swipe. UIKit reports the commit/cancel
    /// result here, before the settling animation completes.
    func endInteraction(isCancelled: Bool) {
        isInteractive = false
        self.isCancelled = isCancelled
        for handler in interactionHandlers { handler(self) }
    }
    func finish() {
        let pending = completions
        completions.removeAll()
        for completion in pending { completion(self) }
    }
}
#endif
