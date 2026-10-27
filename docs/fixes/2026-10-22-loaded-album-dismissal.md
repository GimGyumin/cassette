# Loaded album dismissal — build 1023

The supplied device log contains one home-path push (0 → 1), one pop (1 → 0),
and one appear/disappear pair for the same album instance. It does not show a
second navigation push or page creation. Wikipedia connection errors and the
eventual MusicBrainz cancellation belong to secondary metadata enrichment;
the log alone does not establish them as the visual glitch's cause.

Inspection found view-identity changes after primary album loading. The More By
shelf changed a conditional bottom-margin wrapper even though that wrapper has
no effect on iOS. The top-bleed and status-bar modifiers also selected different
content branches at runtime. These wrappers now keep their content identity as
the shelf, scroll position, and chrome change.

The existing UIKit lifecycle bridge now invalidates the album's load generation
at willDisappear, before the native transition completes. Late related-album,
description, label, local-fallback, and download-state results cannot publish to
the departing page. It leaves the last visible content and loading flags intact
instead of resetting the page during the zoom. Artwork and scroll callbacks also
ignore the departing page. A cancelled back gesture or return from an artist
page resumes unfinished loading when the page appears again.

The native zoom transition and its source-card relationship are preserved.

Validation:

- iOS Simulator build-for-testing passed; no warnings or errors.
- AlbumDetailOfflineTests and LyricsAndChromeRegressionTests passed (43 cases).
- New regression test holds a related-artist response until after primary content
  is displayed and departure begins, then verifies that late results and loading
  flags do not alter the outgoing frame and loading can resume on return.
- No iOS simulator runtime is installed, so device-level animation reproduction
  and interactive UIKit transition tests still require an iPhone/runtime.
