# Cassette energy/work audit — 2026-10-03

The supplied Apple Music comparison is a design reference, not evidence of Apple's
private implementation. These changes use public SwiftUI, Observation, concurrency
and SwiftData APIs in the existing workspace.

## Changes

| Area | Previous work | Current behavior |
| --- | --- | --- |
| Server reachability | A loop woke every 500 ms, including while backgrounded; healthy ping every 20 s | Observation reacts to account/network changes. One scheduled healthy probe every 60 s, explicit retry/foreground checks immediately. No background probes. |
| Server outages | Fixed retries every 3 s | Retry delays 3, 6, 12, 24, then 30 s; network/account changes reset the delay. Concurrent checks share a request. Cancelled/stale requests cannot publish results for a new account. |
| Playback persistence | Position checkpoint every 5 s; full saves repeatedly encoded the queue | Checkpoint every 30 s with 3 s scheduling tolerance. Pause, track/queue changes and background flushes remain immediate. Identical snapshots skip saving; unchanged queues reuse encoded data. |
| Session sync | No save snapshot cache | The cache is checked against the winning persisted session so newer CloudKit data invalidates local deduplication. Clear/restore invalidate it too. |
| Wrapped stories | A 50 ms loop updated root progress, also waking while paused/on the final slide | One deadline per slide. A small progress-bar view animates independently. Pause/background cancel the deadline and preserve elapsed monotonic time. |
| Wrapped medal | 24 Hz TimelineView rotation and whole-medal drawingGroup | Repeating system-managed transform on the ring alone, gated by visibility, scene phase and performance budget. |

The interval changes are code-level reductions, **not measured battery savings**.
In particular, the longer session checkpoint means an abrupt crash can lose about
30 seconds of position (plus scheduler delay); ordinary pause/background saves do
not wait for that checkpoint. A silent server outage can take up to the healthy
probe interval to detect; explicit retry and foreground/network changes check sooner.

## Existing safeguards retained

- Album and artist layouts use lazy stacks/grids.
- ArtworkImageCache has size tiers, bounded memory, request deduplication and
  detached image decode/downsampling. Memory warnings clear regenerable artwork.
- Album/playlist song mapping is prepared asynchronously outside UI work.
- Lyrics tracking already stops when hidden, inactive or paused. Beat visualization
  is gated by active UI consumers and the performance budget.
- Decorative gradients, marquee text and artwork prefetch respect visibility or
  the shared thermal/low-power/background policy.
- Core playback progress/end-of-track checks remain active during background audio.
  They are not decorative timers: removing them would risk scrobbling, gapless
  preparation, recovery and automatic next-track behavior.

## Follow-up: first-use and large-library work

First sign-in now opens the library before optional setup. Full-resolution artwork for the entire
library is opt-in from Settings → Storage; visible covers continue to load on demand. The local
search index limits and pages result sets instead of ranking every match after each query. Failed
index preparation is reported and online search falls back to the server. These changes reduce
potential work, but their battery, storage and latency effects still require device measurements.

## Verification

Focused tests cover network/account observation, concurrent checks, background
cancellation, stale results, bounded retries, duplicate writes, queue preservation,
CloudKit winner changes, clear/restore, and story pause/resume timing. Existing
playback-engine and performance-budget tests cover the retained playback policy.

Validation completed: 29 focused tests passed on macOS; unsigned generic iOS build
reported `BUILD SUCCEEDED`. Logs: `/tmp/cassette-energy-tests.log` and
`/tmp/cassette-energy-ios-verified.log`. This does not exercise signing or physical
device energy/audio behavior.

For actual energy validation, compare the same physical device/library/network in
Instruments (Time Profiler, SwiftUI and Energy diagnostics): idle foreground,
album/artist scrolling, 10 minutes of locked-screen audio, network recovery, and
Wrapped pause/background/resume. Track wakeups, requests, disk writes, main-thread
work and animation hitches; do not infer battery or thermal gains from build/tests.
