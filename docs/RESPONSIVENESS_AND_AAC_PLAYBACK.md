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

## Playback

Navidrome's AAC route checks the cached OpenSubsonic capabilities before using
[transcodeOffset](https://opensubsonic.netlify.app/docs/extensions/transcodeoffset/).
Supported streams restart encoding with timeOffset; servers without that extension retain
their existing engine-seek path. Subsonic offsets use whole seconds.

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

## Verification scope

Regression tests cover request parameter preservation, Navidrome seconds/Jellyfin ticks,
absolute response clocks, backward offset replacement, clock reset on stop/repeat, short-response
classification, and bounded/account-scoped immutable history snapshots. Existing playback,
Jellyfin, offline-artwork and search tests are included in the focused validation.

Builds and tests do not measure device frame rates or exercise the user's live servers.
Physical-device validation should compare search focus, vertical/horizontal home scrolling,
tab reselection, and AAC forward/backward/paused seeks on both servers, including Bluetooth.
Use Instruments' Time Profiler/SwiftUI diagnostics to measure main-thread work and animation hitches.
