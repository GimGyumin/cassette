# Build 1007 — Album preparation, search, and selection colors

This supersedes build 1006's on-demand edge analysis and edge-colored page canvas.

## Artwork preparation and background

- Only `AlbumCoverPreloadService.prepareTheme` requests presentation/edge analysis.
  Loading a grid thumbnail or entering/uncovering an album reads cached facts.
- Launch, onboarding, and library-change preparation analyze cached album artwork
  without fetching missing images. Opt-in original downloads retain their full
  preparation stage. A local analysis pass cannot consume a full-download request.
- Preparation runs one bounded analysis at a time off the main actor. Constrained
  budgets add pacing only for newly analyzed images, rather than changing colors
  or sleeping for every cached album. Results are persisted and aliased by album ID.
- Version 2 preparation restores the existing dominant-color algorithm; measured
  edges decide full-width suitability without replacing the page's background.
  Manual color overrides still take precedence.
- Account/generation/cover-revision tokens reject stale work after account changes,
  cover replacement, or cache eviction. Prepared aliases use account-scoped lookups.

## Search

Local query debounce is 80 ms (previously 300 ms). HTTP retains a 300 ms quiet period.
Indexed results publish before the download database scan finishes; download flags
and local-only songs are merged afterward. Request and presentation generations
still prevent stale responses from replacing a newer query.

The first server page is ranked immediately. It no longer waits for a speculative
second page, and subsequent pages are requested on demand. Independent offsets,
deduplication, and repeated-page termination remain intact. These changes remove
intentional waits; no on-device end-to-end latency multiplier is claimed.

## Navigation and settings

Album zoom routes use a stable page-local identity rather than hashing a changing
album payload. Tab-bar color observation lives below the NavigationStack owner,
so restoring chrome on a pop does not re-evaluate all destination builders. The
native zoom/back gesture remains in use. Removing page-triggered palette work also
prevents a late layout/color decision during dismissal.

Settings choice rows use a plain button style and explicit primary/secondary colors.
Only the selected checkmark uses blue; titles and descriptions no longer inherit
the form's button tint. Selection bindings and VoiceOver selected traits are retained.

## Verification

Focused tests cover first-page request count/paging, indexed results before a blocked
download scan, stale responses and cancellation, disk-only preparation/album aliases,
background-palette preservation, account isolation, replacement artwork, and existing
color/lock/offline/download behavior.

Final iOS Simulator compilation (arm64 and x86_64) and the focused native macOS
test run passed without compiler warnings or errors. The built iOS app reports
`CFBundleVersion=1007` and `CFBundleExecutable=Cassette-1007`.

- Build log: `/tmp/cassette-1007-final-ios.log`
- Test log: `/tmp/cassette-1007-final-tests.log`
- Test result: `.derivedData-mac/Logs/Test/Test-CassetteTests-2026.10.21_11-57-44-+0900.xcresult`

Native iPhone zoom dismissal (including an interrupted/cancelled swipe) and the settings
appearance still require on-device verification; no usable iOS Simulator runtime is
installed on this Mac.
