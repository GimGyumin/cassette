# Original-log playback and efficiency audit

## Evidence and limits

The supplied two analysis documents are hypotheses and recommendations. Counts
below were independently checked against the original
`Cassette-80DB144B-FC70-4D13-86DA-963A1532DCA0.md` (Cassette 1.0/1001,
iOS 27.2 beta 24B5110a). The two earlier general-analysis attachments were duplicates.

- 32,585 lines / 5,243,035 UTF-8 bytes, including a truncation marker.
- 3 automatic download failures; the same song failed twice one second apart.
- 1 AudioStreaming underrun message and 1 AVPlayer waiting message at
  2026-10-15 23:37:29 UTC. An engine stop and new native item occur in the same
  second. The log does not prove their causal order or the audible gap duration.
- 1 wrapped SwiftSonic URL cancellation logged as a lyrics error.
- 6 missing `saxophone` symbol warnings.
- 1,005 NPIC sends and 402 identical-info skips. There are 2,010 matches for the
  broader NPIC method name because each send also has a finished record.
- 15,440 UIKit dynamic-keyboard warnings. These are not a count of screen renders.
- 7 large request summaries total 552,354,010 response bytes. Two failed requests
  account for 183,454,969 bytes; their summaries alone do not identify which cache,
  streaming, or offline-download owner discarded or retained the bytes.
- Only 14 entries use an app.cassette subsystem. Most retained entries are system
  diagnostics. Export time is 2026-10-16 02:19:41 UTC, but the file ends at
  2026-10-15 23:39:31 UTC: the former exporter stopped at the *oldest* 5 MB.

No battery, CPU, GPU, memory-leak, or crash measurements were inferred from these
counts. Device profiling and listening tests were not available.

## Changes

### Playback metadata and widgets

`periodicNowPlayingPush` no longer publishes a time every five seconds. It retains
the separate 30-second server report. Start/stop, pause/resume, seek, recovery,
queue, and artwork events retain their existing publication fences. The redundant
track-start `publishTrackChange` + `update` pair now uses `update`, which itself
publishes metadata before loading artwork. Obsolete five-second throttle state
was removed. The two immediate same-kind widget reloads on one track start were
reduced to one after its cover and color preparation.

This follows [Apple's elapsed-time contract](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime):
the system extrapolates time from the last position and playback rate. The modern
iOS 27 MediaSession bridge and legacy compatibility metadata remain; their mere
presence in the log is not proof of a duplicate app player.

### Downloads, cache, HTTP, and cancellation

- When automatic offline storage is enabled, the delayed ephemeral cache task
  does not start another whole-file request using a different cache preset.
- Automatic storage now waits for five seconds of advancing playback, plus at
  least ten buffered seconds on a native remote item. Initial buffering is not
  mistaken for healthy playback.
- Automatic failures have an account-revision/song/quality-specific cooldown
  (at least 60 seconds, then 300), honor a longer Retry-After, and stop after three
  failures for that key. The bounded in-memory history does not block explicit
  user downloads; new credentials/quality produce a new key. Cancellations do not
  consume this failure budget.
- Background audio HTTP rejection, regular downloads, and cache transfers now
  preserve status, endpoint filename, stage, and Retry-After instead of replacing
  the response with a bare -1011. Actual transport failures add domain/code/status
  and received byte count. URLs with queries, credentials, headers, and arbitrary
  server bodies are not added to these diagnostics.
- Wrapped SwiftSonic cancellations now leave LyricsService as CancellationError,
  rather than being logged and surfaced as a network failure.
- The existing validated completed-transfer reuse, permanent/cache coordination,
  account fencing, and audio-file validation remain. Arbitrary partial streaming
  bytes are **not** installed as completed audio or concatenated without verified
  representation and range identity. This work does not add a general partial
  stream cache/resume system.

### External metadata

MusicBrainz now retries HTTP 429/5xx as well as selected transient URL errors, with
bounded exponential waits and numeric/date Retry-After support. A shared host
cooldown also applies to concurrent lookups. Throttle waiters recheck the reserved
slot after actor suspension, preventing simultaneous wakeups from sending a burst.
Cancellation stops waiting. Authorization failures do not retry; failed searches
do not fan out into looser queries and recording-detail lookups, and a short
negative cache suppresses immediate repeats.

[MusicBrainz documents 503 as a rate-limiting response](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting),
so it cannot automatically be labelled an outage. Existing SwiftSonic retries
already cover ordinary library API 429/5xx; a second blanket retry layer was not
added there.

### Engine and search

The checked-out AudioStreaming dependency fixes its output format to stereo
44.1 kHz (`AudioPlayer.swift`, outputAudioFormat). Non-44.1-kHz lossless sources
now request native decoding; the resolved lossy-transcode guard continues to take
precedence over original lossless metadata. Native gapless preparation remains
available. Current Playback shows the iOS audio session's sample rate separately
from source metadata. Session rate is not a measurement of DAC bit-perfect output.

The delayed underrun handler now rechecks the command and active engine after its
400 ms grace period. An old streaming callback cannot cancel a newly active native
item's preparation. Only a sustained, still-current underrun is logged, with epoch
and position; engine starts have separate notice-level diagnostics. Stopped/failed
AudioStreaming instances are still replaced because reusing them previously let
asynchronous cleanup erase the next track. Prepared gapless/native queues retain
their established reuse path.

Search uses the supported `pianokeys` icon for Jazz and avoids assigning an already
active search focus again. No focus/layout feedback loop was established in the
source or log; the beta UIKit warning is not claimed to be fixed by this change.

### Export completeness

Exports retain available Cassette/SwiftSonic diagnostics plus system errors/faults,
bounded to the newest complete UTF-8 records within 5 MB. They no longer stop at
the oldest records before reaching the reported incident. A clear omission marker
is included when the byte budget is exceeded. Existing redaction and the bounded
20-session archive remain. OSLog availability still determines which app log levels
can be recovered; this is not a full device sysdiagnose.

## Validation

No simulator was used. Related macOS tests cover bounded retries and Retry-After,
HTTP diagnostics without credentials, wrapped lyrics cancellation, absence of
periodic system publications, preserved state-event publications, native
sample-rate routing, newest-log retention, lock-screen zero seek, playback recovery,
gapless clock continuity, transfer coalescing, and background download recovery.

- Final macOS arm64 result: **84 test definitions / 95 executions passed, 0 failed,
  0 skipped, no reported runtime warnings**.
  `/tmp/cassette-log-audit-verified-tests.log`
  `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.16_12-17-52-+0900.xcresult`
- Final iOS Generic Device build, signing disabled: **BUILD SUCCEEDED**, no compiler
  warnings/errors in the build log. `/tmp/cassette-log-audit-complete-ios.log`
- `git diff --check` passed for the changed files.

Physical-device checks remain: actual audible gaps on slow Wi-Fi/cellular,
lock-screen progress interpolation, Bluetooth/USB output sample rates, keyboard
behavior on iOS 27.2 beta, and Instruments energy/CPU/GPU/allocations measurements.
Neither network byte savings nor battery improvements have been measured.
