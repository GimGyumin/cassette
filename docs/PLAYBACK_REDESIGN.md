# Playback redesign — 2026-09-28

This document supersedes older descriptions of handover warm GETs, first-track speed
probes, parked outgoing AVPlayers, and pause/play stall nudges.

## Basis and boundaries

Apple Music's internal selection, buffering, and prefetch algorithms are not public.
This implementation follows public AVFoundation behavior, not an asserted replica of
Apple Music. Apple documents ALAC/FLAC in HLS using fMP4; that requires compatible
server packaging. A client cannot turn a Subsonic progressive endpoint into a CDN or
segmented lossless service by changing a buffer constant.

References:

- [Apple HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/)
- [AVPlayer automatic stall avoidance](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling)
- [Forward buffer preference](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration)

## Request ownership

`PlayerService` owns one cancellable preparation task. A new valid selection cancels
the previous task, including its resolver requests and retry delay. Pause and stop
also cancel preparation. Cancellation is not presented as a playback error.
Epoch checks reject work from superseded selections after actor suspensions.
The resolver checks cancellation before network fallback, so cancelling Jellyfin
resolution does not launch another request through Subsonic.

Downloaded and cached files retain priority. A remote resolve never performs a
second audio GET for warmup or speed measurement. Existing fresh measurements can
be consulted; unknown bandwidth uses the user's network-specific quality. Automatic
can subsequently learn a lower quality ceiling from actual playback failures.

## Buffering and next-track preparation

| Path | Startup | Sustained playback / recovery |
| --- | --- | --- |
| iOS AudioStreaming stereo | 1 second of decoded audio | 30-second reservoir; 5 seconds before resuming after underrun |
| AVPlayer remote | Forward preference 0 (system chooses), automatic stall avoidance enabled | After playing: 10-second preference, 20 seconds on a limited link |
| AVPlayer local | System defaults | No network buffer preference |

These values are buffer durations, **not wall-clock startup guarantees**. The AVPlayer
forward duration is a preference, not a mandatory startup threshold or strict cap.

Only one AVPlayer is audible/owned. Explicit track selection stops the old source;
the previous title's audio is not kept playing to mask loading. iOS stereo retains
its existing engine queue for natural gapless transitions. Preparation polls for
actual current-track playback before resolving the next entry, is cancellable, and
rechecks the queue before arming. HLS sources never enter the progressive engine's
queue. Crossfade and device-budget arbitration still apply. Buffering the next selected song
is treated as continuous streaming rather than offline caching: it uses the active
network's streaming quality, including on cellular. Background audio retains this
buffering; only critical thermal or memory pressure inhibits preparation.
The follow-up now uses AVQueuePlayer on the system path as well: at most one successor
is inserted ahead of EOF and currentItem identity confirms the transition. No new
player is created at that boundary. Actual continuity still depends on compatible
media and the server supplying enough data.

The redundant full-file background cache transfer is skipped on limited links even
when cellular caching is allowed. On other links it checks that the same track is
still playing after the delay. Explicit downloads retain their existing behavior.

## Recovery

One watchdog samples media time every second during both initial loading and
playback. Twelve seconds of continuous lack of progress, together with AVPlayer's
inability-to-play signals, allows recovery. Brief hiccups, seek settling, resumed
progress, and a healthy buffer reset the observation window. No artificial
pause/play cycle is used to nudge the clock.

Only Automatic quality can step down. Explicit lossless, local files, radio, and
Dolby/multichannel are excluded; routing itself is always automatic now that the
playback-method menu is gone, so there is no explicit route left to protect. A track
gets at most one attempt and attempts have a 30-second session cooldown. The
re-resolved source and saved position are installed only if both selection epoch
and player generation still match. The effective quality ceiling also reaches
Jellyfin route selection so a recovery does not accidentally select the original
high-bitrate stream again.

The learned ceiling is session-scoped; this change does not introduce speculative
upgrades or active bandwidth probes. Explicit quality remains under user control.

## Energy, downloaded artwork, and Live Activity follow-up

- Audio-thread sampling now uses atomic gates tied to playback, visible consumers, and
  the performance budget. Paused/background/Low Power Mode/thermally constrained
  playback cannot keep calculating beat bands just because a SwiftUI view is retained.
- The background progress loop wakes once per second instead of twice. Core audio
  decoding and gapless preparation continue while the screen is locked.
- Permanent downloaded covers are resolved before derivative disk files or network
  requests. Player artwork resolves local hero and thumbnail copies before requesting
  remote artwork; macOS also preserves existing color analysis instead of invalidating
  it on every player presentation.
- Live Activities show a stable phase symbol, localized title, progress, and server
  name. Lock Screen and expanded/compact Dynamic Island layouts share the same state.
  Unknown totals remain indeterminate; terminal states use a checkmark or warning.
- Per-album App Group image copies for preparation activities have been removed.
  Nonterminal activity updates are deduplicated and limited to one per five seconds;
  phase changes and completion remain immediate. Update/end calls are serialized.
  Owned preparation passes ignore duplicate external progress reports.
- Seeks, shuffle, repeat changes, and queue edits invalidate a queued successor and
  its metadata together. The progress loop prepares the new successor after playback
  resumes. A stereo underrun cancels speculative/cache transfers so current audio
  gets priority before next-track preparation is retried.

Apple describes queuing the next item ahead of time in
[Transition media gaplessly with HLS](https://developer.apple.com/videos/play/wwdc2021/10142/).
The Live Activity layout follows the glanceable progress guidance in
[Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities).

## Validation and remaining device checks

The follow-up macOS build and targeted tests completed with **25 passing tests and
zero warnings** (`/tmp/cassette-energy-gapless-macos.log`). These cover the performance
budget (including locked-screen gapless eligibility), beat analysis, gapless policy,
request cancellation, and stall monitoring. This run includes the AVQueuePlayer code
but does not measure audible transitions through a real server.

After that run, the seek/underrun queue cleanup, duplicate preparation-report guard,
and serialized ActivityKit updates were tightened. A downloaded-cover regression test
was also added. The final expanded macOS rerun and the iOS build were not approved,
so these final additions are not reported as passing tests. The iOS-only Live Activity
has not been rendered or inspected on a device in this session.

Before release, run the final targeted suite and iOS build. Exercise consecutive
album tracks, queue edits, seek, shuffle, lock/unlock, repeat-one, Bluetooth/AirPlay,
local/offline artwork, and cellular variability. Verify currentItem transitions do
not restart playback or advance metadata twice. Check short tracks and incompatible
codec/channel transitions separately; an engine switch cannot promise a seamless
boundary. Compare Energy Log/CPU samples and battery drain over identical sessions.
No device temperature, battery percentage improvement, or acoustic gap duration was
measured here.
