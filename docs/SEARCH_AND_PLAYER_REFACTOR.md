# Playback decomposition and complete search

## Playback ownership

`PlayerService.swift` now contains stored state, construction and dependency wiring (344 lines,
previously 4,624). Actor extensions own each implementation area:

| File suffix | Responsibility |
| --- | --- |
| Transition | Accept/cancel play requests, resolve and start playback |
| Gapless | Prepare the next entry and reconcile a native handover / end of track |
| Engine | Engine selection, native event reconciliation and quality recovery policy |
| AudioSession | iOS session, interruptions, screenshots and output-route recovery |
| Controls | Pause/resume, stop, seek and skip |
| Queue | Queue mutations, shuffle and automatic extension |
| Session | Restore and periodic persistence |
| Progress | Progress sampling, seek settlement and EOF fallback |
| Crossfade | Prefetch and volume fades |
| Reporting | Scrobbling, listening statistics and cache writes |
| Artwork | Cover preparation and ISRC metadata |
| NowPlaying | Snapshot publication and playback reports |
| Callbacks | AudioStreaming callbacks and underrun adaptation |

The initial extension split preserves actor ownership for transition/session policy. The native
transport is now an independent `AVPlayerPlaybackEngine`: it owns AVQueuePlayer, the next item,
KVO/end observers, seek completion fencing and the cancellable stall watchdog. Its immutable events
carry a generation and, where applicable, item identity. PlayerService handles queue metadata and
quality policy, and rejects stale events. Common transport uses `PlaybackEngine`; only the
`AudioStreamingPlaybackEngine` subprotocol exposes the AudioStreaming delegate.

A late restore seek cannot restart an outgoing native player, and completion honors any newer play/pause input. Queue handover is consumed once without
restarting the incoming item. Stop clears observations, prepared items and watchdog ownership.
Independent transition/audio-session coordinators remain a larger architectural follow-up; the
extension split alone is not a claim that all PlayerService state has been separated.

## Other large files

The same behavior-preserving split applies to `LyricsViewModel` (1,752 → 265 lines),
`AlbumDetailView` (1,575 → 523), `PlaylistDetailView` (1,490 → 374) and
`NowPlayingService` (841 → 96). Lyrics translation, seeding, chorus and tracking live in separate
extensions of the same observable model. Album extensions extend **AlbumDetailContentView**, the
observation-owning child, preserving the outer view's stable navigation/theme boundary. Playlist
layout, actions and editing remain on the original view. Now Playing artwork, snapshot updates and
remote commands retain their original actor ownership. This stage changes file organization, not
SwiftUI view identities or observation boundaries.

## Search correctness

Previously the UI called `search3` without count/offset parameters (server default: 20 per kind),
filtered artists when `albumCount` was absent/zero and hid the local index once any server result arrived.

The app now searches a persisted local catalog by default. The index contains songs as well as artists,
albums and playlists, stored in a per-server JSON snapshot. Library enumeration requests 500 songs per
page and continues until an empty or repeated page, even when the server returns smaller pages.
Tokenization runs once on a utility task; publishing is guarded by account and rebuild generation.
Snapshots load without a network request when offline, and logout clears stored catalogs.

Indexed results have no arbitrary 20-item cap. Download metadata is merged by song ID. Typing into
search does not call the server when an index is supplied. The compatibility path without an index
retains independent 50-item search pagination, cancellation fences and ID deduplication.
Offline scope replaces “Library” with “Indexed Music”; “Downloads” remains available.

Search navigation destinations stay in the observation-free `SearchView` shell. Query/focus/scope and
results live in child views. The design uses a capsule field, circular cancel button, scope selector,
category chips, query suggestions derived from actual matches and flat cover/title/type rows.

## References

- [OpenSubsonic search3](https://opensubsonic.netlify.app/docs/endpoints/search3/): separate counts and offsets.
- [Apple AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer): native queued playback.

This structural refactor does not establish lower power consumption or audible gaplessness by itself;
those still require measurements on a device with the actual server, formats and routes.

## Original artwork and preparation

Full-resolution downloads request no server resize parameter and save validated response bytes
verbatim as `<id>@original-v1`. Existing `@hero` derivatives no longer count as original downloads.
The cover-preparation migration runs again to replace previously resized caches. Existing offline
covers remain available as a fallback. Disk originals outrank RAM and streaming derivatives; decoded
UI images remain bounded to 240/1200px and concurrent decodes are coalesced.

CoverArtView and Now Playing refresh when an original arrives. The native artwork provider can fetch
a current track's authenticated artwork in the background even when no download exists. Other
background artwork work remains restricted. Failure retries use bounded backoff.

Recently downloaded albums/playlists now use a vertical adaptive grid. Preparation Live Activities
show a shared 128px cover, its darkened average color and a measured ETA for the current cover phase.
No ETA is invented before enough progress is measured. Payloads carry a shared-file ID and small
metadata, never original image data. Updates remain throttled to five seconds except phase/terminal
changes. See [Apple's ActivityKit constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities):
the extension cannot fetch images from the network and activity state is limited to 4KB.

## Validation

The previous structural split passed 81 macOS regression tests. This follow-up adds checks for
byte-identical full-resolution persistence despite an existing streaming thumbnail, local-original
priority, full short-page indexing, offline snapshot restoration/account isolation, native queue
cleanup, and measured phase estimates. The macOS app and 33 selected regression tests passed with no compiler warnings
(`/tmp/cassette-original-index-final.log`). This includes all newly added cases and the existing
search, cancellation, gapless-policy and Now Playing tests. `git diff --check` passed.
The iOS Simulator app and widget build also succeeded for arm64 and x86_64
(`/tmp/cassette-original-index-ios-complete.log`, including the final restore-seek guard). It retains the documented pre-existing iOS 27
`MediaSessionRepresentable` actor-isolation warning. The build caught and fixed an iOS-only
cross-file access modifier left behind by the initial extension split.
After the final restore-seek play/pause intent guard, all seven engine/cancellation tests passed again
(`/tmp/cassette-native-engine-final.log`).
Audible gaplessness, battery/thermal behavior and lock-screen presentation still require real-device
validation with the user's server, codecs and output routes.
