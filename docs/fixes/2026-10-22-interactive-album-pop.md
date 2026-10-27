# Interactive album pop — build 1026

Device report: toolbar back now works, while swipe-back finishes visually, then
briefly shows the album again. The remaining target is the interactive transition
lifecycle rather than another route push. A device trace of this new build is
still needed to confirm the visual result.

Changes:

- AlbumPresentationController registers a completion during willAppear, before
  the interactive zoom settles. didAppear no longer immediately resumes loading
  while that completion is pending. A cancelled swipe can resume after settling,
  provided the page is still the navigation stack's top controller. A completed
  pop or a later departure invalidates queued return work through a revision.
- ChromeAppearanceController registers departure completion during willDisappear.
  Previously it tried to obtain/register the coordinator at didDisappear; if the
  coordinator was already unavailable, it released the album's root chrome on the
  next main turn without waiting for the gesture's settling animation. That release
  now waits for the coordinator captured at departure and ignores cancelled/stale
  transitions.
- Late appearance callbacks from a popped page cannot reacquire root chrome:
  both appearance controllers verify the cached navigation page is still topmost.
- Width callbacks cannot resize the outgoing artwork once page updates have been
  suspended. Existing guards on palette, scroll offset and late metadata remain.
- Native NavigationLink, Zoom, toolbar-back handling and source IDs are unchanged.
  No view hiding, removal, gesture disabling, private API, or timed hiding is used.

UIKit regression fixtures cover a cancelled swipe waiting for settling, a stale
didAppear after a committed pop, queued return cancellation, and root chrome
remaining unchanged even when the coordinator disappears before didDisappear.
The test coordinator is supplied by a test navigation container, rather than
overriding the production gesture delegates or transition implementation.

UIKit distinguishes the gesture's interactive/noninteractive state change from
the end of the transition. See Apple's
[interaction change documentation](https://developer.apple.com/documentation/uikit/uiviewcontrollertransitioncoordinator/notifywheninteractionchanges(_:))
and the installed SDK UIViewControllerTransitionCoordinator.h contract for
animate(alongsideTransition:completion:).

Validation:

- Final arm64 iOS Simulator build-for-testing passed with no warnings/errors.
  All five UIKit lifecycle/coordinator tests compile. They have not been run.
- macOS AlbumDetailOfflineTests + LyricsAndChromeRegressionTests: 44 passed,
  zero failed/skipped (xcresult summary).
- git diff --check passed. No forced visibility/removal or timed hiding was added.

The machine has no iOS simulator runtime. Actual interactive gestures and the
reported visual flash still require checking on an iPhone; compilation and
macOS tests alone do not verify the device-only animation result.
