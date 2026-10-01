# Player clock and artist navigation fixes — 2026-09-28

- AudioStreaming's duration can be a byte-count/bitrate estimate. A transcoded response can report an original length alongside a different bitrate, so the estimate must not replace a valid catalog duration unconditionally. Estimates within 5% (at least 2 seconds) can refine catalog metadata; large disagreements keep the catalog value. Native AVPlayer timelines remain authoritative. Missing/nonfinite durations are handled explicitly, without limiting genuinely long recordings.
- The progress ticker checks the playback epoch and current song, skips handover samples before seek reconciliation, and publishes position and duration together. An outgoing engine cannot populate an incoming track's clock during resolution.
- Home/Discover destination registration now sits outside the reachability branch. A cellular connection change no longer removes the destination declaration behind an existing navigation path.
- Album detail renders its skeleton/content/error directly over its cached themed background. It no longer depends on a delayed task to remove an opaque, full-page loading cover.
- Artist/album pages keep the native back button. The custom-back bridge used by playlists temporarily installs its own delegate only while visible, refuses overlapping transitions, and restores the previous delegate on departure. It no longer clears the shared delegate on every layout pass. (Partly superseded — see the edge-swipe follow-up below: the artist page and every plain-pushed album page now arm that bridge too, because the native button alone does not keep the *gesture* alive when a page is reached from another pushed page.)
- The artist hero now forwards its melt target to the actual background renderer. Header and body use the same page color in a zero-spacing stack, removing the horizontal color seam above Latest Release. Artist loading shows a skeleton until the artist request resolves.

Validation: 19 macOS regression cases passed, including the actual PlayerService progress timer correcting a 6061-second estimate to a 247-second song, handover clock isolation, duration edge cases, native engine ownership and playback cancellation. See `/tmp/cassette-artist-clock-verified.log`. iOS Simulator arm64 builds cover the UIKit gesture bridge; no actual iPhone back-button/edge-swipe or screenshot acceptance test was performed in this session.

## Follow-up — artist page seam, artist page back button, sign-in sheet (same day)

Reported from a build produced at 11:14 (before the changes above): a hard horizontal seam above
`Latest Release`, an artist page reached from an album page / Now Playing that rendered blank with a back
button that did nothing, and several sign-in flow details.

- **Seam.** `PlaylistThemedBackground` flattened the blur *and* the tone gradient into one
  `.drawingGroup()` bitmap. A page tone that resolved on a later pass jumped to its final colour inside the
  raster while the page background interpolated with `CassetteAnimation.theme`, so the hero's last rows and
  the body held different tones — a hard line at the section boundary. Only the blurred cover is rasterized
  now; the tone gradient stays live and carries the same theme animation as the page backdrop. The artist
  page also uses the album page's `AlbumAtmosphereBackground` (one solid page tone, theme-animated) instead
  of a raw `.background(bodyColor)`, and reads the same bottom-strip tone on a warm cache that the cold path
  stores (`bottomStripColor(for:image:)`), so the tone cannot differ between visits.


- **Back button / blank artist page.** Four mechanisms removed:
  1. `HomeDestination.artistPush(id:name:coverArtId:token:)` — `HomeDestination` artist values are equal by
     content and `NavigationStack` maps an equal path value onto the entry that already holds it, so pushing
     the same artist from a deeper page popped the stack instead of stacking (the album page's previous
     `artistById` workaround only avoided the *parent* case). The album header uses one token per album page
     instance; the player notification uses one token per tap.
  2. Player / notification navigations **append** to the tab the user is in (Back returns to the page they
     came from) and wait for the presentation to disappear (`hasPresentedViewController` poll, bounded)
     before mutating the path — a zoom-dismissed full-screen cover keeps a presentation layer on top for a
     runloop, and a path change inside that window left the pushed page under a stale layer: blank content,
     dead back button.
  3. The artist page's biography no longer uses `.navigationDestination(isPresented:)` from inside a pushed
     page (a stack desync hazard); it is a sheet with a Done button, like the album description sheet.
  4. `SearchView`'s destination closures no longer read `container` / `serverState`; `HistoryRecordingView`
     reads `appContainer` itself, per the regression guard at the top of that file.
- **Sign-in flow.** Local-network discovery has no toggle any more (`discoverLANServers()` is always on;
  the sign-in surface searches on appear and the options sheet retries). The server-address field prompts
  with a bare host (`music.example.com`, verbatim) so the helper text stays the only place a scheme is
  mentioned. Quick Connect stays gated on the probed server's capability and the password entry point is
  only the main form, not "Other Sign-In Options"; that sheet's rows are icon-in-a-soft-box cards like the
  system account sheet. Missing `ko` strings for `Quick Connect`, `Server address`, `Change`,
  `Try Quick Connect Again`, `Instant Mix` and the local-network empty state were added.
- **First-run downloads.** "Download Later" was already offered in all three preparation surfaces
  (`EssentialSupportPreparationView`, `LibraryPreparationView`, the album-covers onboarding step) and can be
  resumed from Storage settings; nothing changed there.

Validation for the follow-up (this session): iOS Simulator and unsigned macOS builds both succeed with zero
errors and only the documented `ConformanceIsolation` warnings; `CassetteTests` run on a macOS destination.

## Follow-up — the transport showed "pause" while a track was still loading (same day)

Reported from a device: tapping a song flipped the play button to the pause (stop) glyph while the stream
was still loading, so the control claimed playback that had not started.

- **Root cause.** `PlaybackState.playing` did not mean "audio is flowing". `performPlay` published
  `.playing` optimistically right after `startEnginePlayback` on the AudioStreaming path (the AVPlayer path
  already waited for `timeControlStatus`), radio published `.playing` as soon as the engine was handed the
  URL, and `resume()` published it even when it had to reopen the stream. All three produced a pause/stop
  glyph (and a `Music Haptics`/bars "playing" cue) for a stream that had not produced a sample.
- **Rule.** `PlaybackState.controlAppearance` now drives every play/pause control: `.loading` renders as
  progress (never as pause), `.playing` as pause, everything else as play. iOS transport controls (full
  player and all three mini-player layouts) adopt the spinner swap macOS already used. A loading control is
  not a button: nothing can be paused before audio exists, and a tap could not do what the glyph promised.
- **Confirmation.** `.playing` is published only by engine confirmation, through one helper
  (`publishEnginePlaybackConfirmation`) fed by AVPlayer's time-control status, AudioStreaming's state
  callback, and — as a backstop — audible progress in the progress ticker (bounded to a fresh start so it
  can never fight a mid-track stall retry or a restore seek). It only ever promotes a pending `.loading`, so
  a user pause during a start is not undone, and a restore that is about to pause itself does not flash the
  pause control. A track-to-track transition still keeps `.playing` (the outgoing track is audible; a
  loading flash mid-skip would be the same lie in the other direction).
- Two related robustness fixes fell out of the wider `.loading` window: the Music Haptics ISRC nudge no
  longer abandons its staggered re-stamps when the first one (4 s) lands while a slow stream is still
  opening, and the incoming track's state is now published *before* the engine starts so an engine that
  begins instantly (a local file) cannot have its confirmation overwritten by that block.
- **Tests.** `CassetteTests/PlaybackControlAppearanceTests.swift`: the appearance rule (`.loading` is never
  `.pause`), the confirmation rule (only a pending `.loading` is promoted; a pause is never undone; a
  restore-into-pause is never promoted), and two real-service resume cases — reopening the stream stays
  `.loading`, while resuming an engine that still holds the track publishes `.playing`.
  Validation: 10 new cases pass; the whole `CassetteTests` suite is green (903 passed, 1 pre-existing skip,
  0 failures) and both the iOS Simulator and macOS app targets build with zero errors.

Not verified: no booted simulator or device is available in this environment (no CoreSimulator runtimes
installed, and the flows need a live server), so the seam, the album → artist / Now Playing → artist
navigation and the onboarding surfaces have **not** been visually re-checked. They need a pass on a device
with a server before release.

## Follow-up — the edge swipe could not leave a page reached from another pushed page (same day)

Reported from a device: tapping the artist name on an album page opened the artist page, but the edge
swipe could not leave it. The page itself rendered (the `artistPush` token fix above did its job) — only
the gesture was dead.

- **What changed.** `ArtistDetailView` now arms the existing `enableSwipeBack()` bridge next to its
  native back button, and `AlbumDetailView` arms it for every push that is not a zoom destination
  (`zoomSourceId == nil || zoomNamespace == nil`). `enableSwipeBack(_:)` gained an `enabled` flag so a
  zoom destination keeps SwiftUI's own gesture delegate, which is what drives its zoom dismissal.
- **Why the native button is not enough.** The interactive pop gesture is vetted by a delegate owned by
  the navigation controller for the page below (or for the transition that presented it), and that
  delegate only vouches for the pop it was installed for. A page pushed *on top of another pushed page*
  — album → artist, artist → album — can therefore lose the swipe, leaving the visible back button as
  the only way out. That is precisely the case the bridge already covered for the playlist page, which
  hides the system button. The bridge only enables the standard pop (stack depth > 1, no transition in flight), so pages
  that never had the problem behave exactly as before.
- **Unverified.** No booted simulator with a live server is available in this environment, so the
  gesture has not been re-checked interactively. A device pass should cover: Home/Library → album →
  artist (swipe back), artist → album (swipe back), and a zoom push (Search → album, swipe back) to
  confirm the zoom dismissal still animates.

## Follow-up — the device log for the same symptom: the stack was being rebuilt (same day)

A device log for the album → artist flow shows the pushed pages being re-created while the artist page was
open: the album page below re-ran its whole load — `[ALBUM] cache hit`, `[ARTIST] cache hit` for the
More-By section, then `getAlbumInfo2` for the description — three times in a row, with the description
fetch failing every time (`✗ getAlbumInfo2 failed on attempt 1`), and the artist page re-ran `load()` too.
A page being destroyed and re-created inside a `NavigationStack` is exactly the state that leaves the
interactive pop gesture dead, so this log is the mechanism behind the report.

- **The tab root no longer changes identity.** `MainTabView.reachabilityGated` used to *swap* the tab root
  between the real content and `ServerUnreachableView()`. A reachability probe that fails while the user is
  deep in a stack — and the log is full of link trouble (`Receive failed with error "Operation timed out"`,
  `nw_endpoint_flow_failed_with_error … already failing`, slow pings) — therefore rebuilt the tab's whole
  stack: every pushed page destroyed and re-created, every `.task` re-run, back gesture gone. The
  unreachable state is now an opaque, hit-testable **overlay** over the mounted content, so the stack
  identity never changes: pages keep their state, their tasks do not re-run, and content plus overlay still
  follow `isServerReachable` exactly as before.
- **The connectivity-keyed reload is idempotent.** `AlbumDetailView`'s `.task(id: isOnline)` now records the
  connectivity value it loaded for and skips a restart carrying the same value
  (`loadedForOnlineState`), so a `NavigationStack` re-applying the same id cannot re-run the album +
  More-By + description load behind an open page. A real transition still reloads, and so do Retry and
  pull-to-refresh, which call `load()` directly.
- **A rebuild is now observable in the log.** `[TABS] MainTabView instance=… appeared` (one line per
  `MainTabView` instance), `[ALBUM-PAGE] task start instance=… loaded=…`, `[ARTIST-PAGE] task start
  instance=…` and `[TABS] unreachable overlay shown/dismissed` make the next device log conclusive: a new
  instance id without a relaunch means the page was destroyed and re-created, and the log says when.
- **Still open — needs a device pass.** `MainTabView.body` still picks its mini-player shell from
  `horizontalSizeClass` (`if usesPadFloatingMiniPlayer … else if #available(iOS 26) … else …`), so a size
  class change (iPad Split View / Slide Over / Stage Manager / rotation) re-creates the whole `TabView` and
  every stack inside it. That is the other known way a pushed page can be rebuilt under the user; it was
  left alone because removing the branch means changing which mini-player API iPad uses, which is a product
  decision. `RootView`'s `needsLibraryIndexPreparation` branch has the same shape, but it only flips during
  first-run preparation, before any deep navigation exists.

