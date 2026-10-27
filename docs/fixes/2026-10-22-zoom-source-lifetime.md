# Zoom source lifetime audit — build 1024

The supplied log shows one path pop and one album disappear, without another
push/appear. That supports investigating the transition surface, but does not
prove a duplicate source, lazy-cell eviction, or an OS snapshot bug.

Source audit:

- AlbumNavigationLink passes the shelf/list's namespace to its source label and
  stores that exact namespace in the immutable navigation route. The destination
  registration remains outside lazy containers, on the navigation root.
- Before this change, all cards in a shelf/list used album.id as the transition
  ID. This does not isolate separate appearances of the same album within that
  namespace. Each link now owns a source ID in @State, passes it to the cover,
  and captures it in the route at tap time. Refreshing album metadata or opening
  another presentation does not intentionally regenerate this source ID.
- Home and library ForEach identity remains album.id. Source IDs are not changed
  in onDisappear, and LazyVGrid/LazyHStack are retained. A truly evicted cell can
  still lose its state; source lifecycle logs now allow this to be distinguished
  from normal disappearance of a retained source while its detail is visible.
- Current album detail does not apply drawingGroup, compositingGroup, glassEffect,
  or blur modifiers to the page surface. No visual effects were disabled without
  device evidence that they cause the issue.

Removed the previous UIKit page-view hiding/restoration workaround completely.
The embedded controller now only suspends pending page updates at willDisappear
and resumes unfinished work at didAppear. It does not inspect a navigation
stack, hide a hosting view, remove a view, or schedule delayed hiding.

Also guarded cancelled return tasks before clearing the model's suspension flag:
a quick return/departure must not accidentally allow outgoing updates again.
The existing loaded-album regression test covers this ordering.

Debug events: [ALBUM-ZOOM] source appear/disappear id=... and open source=...
route=.... The same retained card should report the same source ID when uncovered.

Public API contract: corresponding source ID and namespace are passed to
[matchedTransitionSource](https://developer.apple.com/documentation/swiftui/view/matchedtransitionsource(id:in:))
and [zoom](https://developer.apple.com/documentation/swiftui/navigationtransition/zoom(sourceid:in:)).

Verification:

- The initial 1024 iOS build-for-testing passed, including card-scoped source IDs
  and removal of the hiding workaround, without warnings/errors.
- The first macOS regression run reported 43 passes and one failure in the new
  cancelled-return assertion. The final source checks task cancellation before
  clearing suspension. Its final rebuild/test rerun was rejected by the user,
  so no passing result is claimed for that final revision.
- git diff --check passed.
- Device validation of button-back, completed/cancelled edge-back, and lazy-source
  retention is still required; this environment has no iOS simulator runtime.
