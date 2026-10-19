# Responsiveness and AAC playback — 2026-10-08

The reported combinations are Navidrome/AAC and Jellyfin/AAC.

## UI work

- Album shelves create visible cards with a LazyHStack and retain their explicit height.
- Favorite checks fetch at most one matching record, including server/type/identity aliases,
  rather than materializing every favorite of that type for every mounted card.
- Search history is fetched and converted to value snapshots on SearchHistoryService's actor.
  Its views refresh on history writes and account changes, rather than unrelated mainContext saves.
  The List owns individual rows so it can virtualize them.
- Search focus animates the header/scope chrome without animating the entire history/results tree.
- iPad sidebar roots stay mounted after first selection, preserving navigation and scroll state.
- Local artwork URL resolution combines its server/identity reads into one MainActor hop.
- Search genre covers resolve together on a background task, after the initial tab transition,
  rather than scanning/folding the library once per card in the view body. Cards use 240 px
  thumbnails instead of 1200 px hero decodes. Browse and history remain mounted during focus.
- While initial album tracks load, an opaque, full-page album background covers the unfinished
  header and skeleton. A progress indicator remains visible until the initial load completes.
- Artist pages use the same loading cover and resolve the initial artist artwork tone while
  metadata loads. The supplied artist cover is available before the detail response arrives.
- The shared iOS bottom scroll margin disables the bottom scroll-edge blur. The tab bar/mini
  player still minimizes on downward scrolling, as requested.
- Library content uses a LazyVStack; favorite shelves reserve a stable, Dynamic Type-scaled
  height so horizontal card realization does not alter the enclosing vertical scroll extent.
- Artwork alias lookups and context-menu favorite/pin preparation run off the main actor.
  An actor caches immutable alias/identity indices per server/type and invalidates them after
  identity writes. Historical IDs and account/type separation remain intact. Synchronous alias
  fallback no longer re-fetches the entire alias table inside each alias iteration.

## Playback

Navidrome's AAC route checks the cached OpenSubsonic capabilities before using
[transcodeOffset](https://opensubsonic.netlify.app/docs/extensions/transcodeoffset/).
Supported streams restart encoding with timeOffset; servers without that extension use
native seeking, with complete-response buffering if the server rejects byte-range seeking. Subsonic offsets use whole seconds.

Jellyfin AAC uses Audio/{id}/stream.aac with explicit codec/bitrate, Static=false,
disabled stream copy and CopyTimestamps=false. This avoids Universal's independent
container/direct-play decisions and progressive MP4 indexing at EOF. Seeking uses StartTimeTicks,
as exposed by Jellyfin's
[AudioController](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/AudioController.cs).
HLS continues to use AVPlayer's native timeline.

The service adds the server offset to the new response's zero-based clock. Seeks, recovery,
cold resume, foreground health checks and gapless handovers use or reset that offset together.
Paused seeks preserve pause. Original URLs, custom headers, codec, bitrate, proxy prefix and
Jellyfin media/session identifiers remain available when constructing the next request.

AAC/MP3 transcodes are routed from the delivered format rather than the original file's spatial
metadata. Incomplete remote transcode durations are treated as estimates. A transcode that ends
within three seconds despite over thirty seconds remaining gets one recovery at its retained
position; a repeated truncated response produces an error, rather than cycling through repeat-one.
Repeat-one also clears the previous EOF clock before restarting. AudioStreaming's startup buffer
is two seconds, followed by its existing thirty-second reservoir and five-second underrun recovery.

Follow-up: server-offset streams now use AVPlayer on iOS as well as macOS. Every scrub replaces
the native item and invalidates the previous item's callbacks. A seek request generation discards
superseded requests after actor hops; pause cancels pending seeks. Seeking cancels the old progress
timer and delayed restore-pause task, resets stall/EOF monitors, and starts a new timer when playing.
Cancelled ticks cannot update positions, reconcile a newer seek, or interpret the previous clock
as EOF. Offset seeks stay pinned until the replacement response's media clock advances. Recovery
also retains its server offset when reopening the encoder.

## Finite remote seeks and download quality

Finite remote tracks accept seeks using catalog duration while native seek metadata is still
loading. AVPlayer queues the latest target until the item is ready, cancels superseded seeks,
and resumes only after a successful seek completion. Failed native seeks and item failures
while seeking preserve the target instead of resuming zero/old position. Remote lossy responses
use AVPlayer on iOS as well as offset responses.

A non-offset, non-HLS server response that rejects native seeking is downloaded once into a
temporary file, validated, and reopened at the requested target. Acquisition is fenced by the
track epoch and seek generation; a newer scrub, pause or stop cancels it. The temporary file
is removed on engine stop/track replacement. A server without range support can require a
full response and therefore delay the seek; this does not create a permanent download or
change cache settings. Offset and HLS failures are reported without silently restarting at zero.

Explicit AAC 128/256 download quality is authoritative even for ambiguous/spatial original
metadata. Before committing a download, AVAudioFile verifies the actual codec. A lossless or
higher-bitrate response is converted on a utility worker with bounded PCM buffers to AAC M4A,
at most stereo/48 kHz. Existing AAC within the ceiling is reused. The stored extension, MIME
and lossless metadata match the saved output. Automatic/original downloads keep their policy.

## Manual server delivery method

Audio Quality and Current Playback both expose Server Playback Method; macOS also exposes it
in native settings. Automatic, Direct Play, Universal Transcoding, HLS, Original File and
OpenSubsonic are persisted. Manual Jellyfin methods build their specified endpoint directly,
without requiring PlaybackInfo or silently falling back. Unsupported methods report an error.
The selection applies to the next server resolution; downloaded/cached files retain priority.
Current Playback displays the five server method names verbatim, using resolved route metadata
before URL inference, while local/radio/unknown descriptions remain localized.

## Verification scope

Regression tests cover request parameter preservation, Navidrome seconds/Jellyfin ticks,
absolute response clocks, backward offset replacement, clock reset on stop/repeat, short-response
classification, and bounded/account-scoped immutable history snapshots. Existing playback,
Jellyfin, offline-artwork and search tests are included in the focused validation.

Initial validation: 84 test cases passed (88 runs including parameterized inputs), with no failures.
The unsigned generic iOS build succeeded. Logs: `/tmp/cassette-smooth-verified-tests.log` and
`/tmp/cassette-smooth-ios.log`. The iOS build retains an existing Swift 6 isolation warning in
`CassetteMediaSessionController.swift`; no new build errors were reported.

Follow-up validation: all 76 focused test executions passed, including six consecutive native
offset scrubs followed by paused scrubs in both MP4 AAC and ADTS AAC, obsolete item error/end
callbacks, a cancelled progress tick, and background genre lookup. The ADTS fixture is five seconds
of FFmpeg-generated silence. These playback fixtures test item lifetime/clock behavior locally;
they do not simulate either server's HTTP responses. The final unsigned iOS build also succeeded.
Logs: `/tmp/cassette-followup-tests.log` and `/tmp/cassette-followup-ios.log`.

Scroll follow-up: focused identity, menu-state, artwork, home-data, history and AAC clock tests
passed, as did the unsigned iOS build with the requested collapsing bottom player restored.
New regressions cover alias-cache invalidation, server/entity scoping, identity-only legacy IDs,
and background favorite/pin reads after writes. Logs: `/tmp/cassette-scroll-tests.log` and
`/tmp/cassette-scroll-ios.log`. These checks verify behavior and compilation; device scroll
frame times and tab-transition hitches still require profiling on the affected device.

Builds and tests do not measure device frame rates or exercise the user's live servers.
Physical-device validation should compare search focus, vertical/horizontal home scrolling,
tab reselection, and AAC forward/backward/paused seeks on both servers, including Bluetooth.
Use Instruments' Time Profiler/SwiftUI diagnostics to measure main-thread work and animation hitches.

## Cached/downloaded lyric and slider seeking

- PlayerState exposes the latest absolute pending seek position until the engine lands.
  Scrubber labels and lyric timing share it rather than consuming stale pre-seek clocks.
- Local seek settlement uses 150 ms tolerance (remote segment seeking retains its existing
  2.5 s concession). The previous wide tolerance could accept the old clock on a small seek.
- Local release requests coalesce for 60 ms and preserve the existing audio engine.
  Pause/resume during that interval commits the correct local strategy without reopening
  the file or switching away from its ReplayGain/gapless graph.
- Local settlement checks run every 33 ms for the first second, then at 100 ms. They only
  run while seeking. Playback confirmation waits until the current seek has settled. Both the
  dedicated monitor and progress ticker publish position, pending-clock removal and confirmed
  .playing in a single MainActor transaction; a previous rerun exposed a split-transaction race.
- Lyric taps highlight/scroll immediately; cancelled/stale completions cannot replace the
  newest target. One explicit scroll request replaces competing highlight/token animations.
  Paused slider seeks synchronize lyrics, and explicit small backward seeks bypass jitter
  suppression. Word/translation rendering and normal automatic scrolling remain intact.
- LocalSeekSmoothnessTests covers downloaded and cached provenance, rapid releases, old
  clock rejection, pause during pending work, and actual local AAC AVPlayer seeks. Additional
  lyric tests cover immediate feedback, stale completion and pending/tiny-backward clocks.

Validation of the local-seek correction: final unsigned iOS build succeeded; 58 selected test
executions passed. Actual local AAC playback covers cached/downloaded × playing/paused while
retaining the same AVPlayer. The AudioStreaming path's coalescing, old-clock rejection and pause
semantics are covered with the transport test double, not a physical iPhone audio-session run.
Test log: `/tmp/cassette-local-seek-background-tests.log`. Physical iPhone lyric/slider scrolling
frame-time measurement remains a device check.

Additional shared-path verification: 15 existing transcode-seek and duration-policy test
executions passed (`/tmp/cassette-local-seek-stream-regression.log`), for 73 selected executions
across the final runs. No physical Navidrome/Jellyfin server connection was used in this check.
