# Restore upstream album transition ownership — build 1025

Fetched `https://github.com/CassetteLab/cassette.git`, main commit
`1398af347f797140bbd3941d329d2db4cd5d5365` (2026-10-19).
The README's former MathieuDubart/cassette URL redirects to this repository.
Only fetched/read upstream; did not merge or reset the customized checkout.

Compared upstream AlbumDetailView.swift, HomeView.swift, AlbumsListView.swift,
NavigationTransitions+Cassette.swift, and CassetteSpacing.swift.

Concrete differences corrected:

| Upstream | Previous customized code | Build 1025 |
| --- | --- | --- |
| NavigationLink activates the value destination | AlbumNavigationLink used a Button and appended directly to an environment NavigationPath | Restored native NavigationLink(value:). The existing root path still owns navigation. |
| The state-owning album page applies Zoom as its final modifier | Zoom was attached outside the cache/theme preparation wrapper; the content page's zoom parameters were unused | Pass source ID/namespace through the wrapper and apply Zoom last on AlbumDetailContentView. |
| Plain matchedTransitionSource(id:in:) | Additional source snapshot clipping configuration | Restored upstream's plain source modifier. Existing artwork clipping remains on the cover itself. |
| Top scroll-edge effect is always hidden on album pages; source comments cite flicker | System soft-edge visibility changed with scroll/header state | Restored upstream cassetteHideTopScrollEdgeEffect on the album page. |

Kept immersive artwork, palette caches, sharing, More By navigation, phone player
landscape, stable card-specific source IDs, and the generation/cancellation guards
for late metadata. There is no forced hiding/removal of a navigation hosting view.
The original custom back-button/swipe delegate was not copied: the supplied log
shows one pop, and current system-back navigation does not need that workaround.

These are verified implementation differences. Without device reproduction, they
do not individually establish the root cause of the retained zoom surface.

Upstream source:

- https://github.com/CassetteLab/cassette/blob/1398af347f797140bbd3941d329d2db4cd5d5365/Cassette/Views/Browse/AlbumDetailView.swift
- https://github.com/CassetteLab/cassette/blob/1398af347f797140bbd3941d329d2db4cd5d5365/Cassette/DesignSystem/Platform/NavigationTransitions%2BCassette.swift

Validation of the final source revision:

- iOS Simulator build-for-testing passed, without warnings/errors.
- macOS AlbumDetailOfflineTests + LyricsAndChromeRegressionTests passed: 44 tests,
  zero failures, zero skips (xcresult summary). Includes the cancelled-return and
  late-More-By response regression.
- git diff --check passed.
- Earlier builds overlapped the helper API edits and linked stale object files;
  final builds above completed after all source changes were finished.

Native zoom timing and button/interactive-back behavior still require iPhone
validation: this machine has no installed iOS simulator runtime. Passing unit
tests/builds do not establish that the device-only visual glitch is resolved.
