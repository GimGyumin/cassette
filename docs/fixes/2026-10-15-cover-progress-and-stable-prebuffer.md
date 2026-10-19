# Cover progress and stable next-track preparation

The supplied device log reported 16 prepared originals and 347 missing originals, followed by checks of absent files and ongoing optional palette deferrals. It did not include final cover completion or audio transition logs. Missing-file checks alone are not evidence that valid files were deleted, and this log does not establish the cause of an audible gap.

## Changes

- AlbumCoverPreloadService keeps a previously completed state while checking metadata and disk inventory. It marks downloading/incomplete only after discovering real missing or invalid originals. A no-op reconciliation does not announce the covers phase.
- A utility inventory observer includes images installed by daemon jobs without foreground awaiters. Progress no longer depends solely on the first few admitted workers; worker and inventory counts are combined without double counting. Final failure/completion decisions reconcile the actual files on disk.
- Missing paths are rejected before ImageIO is called, eliminating the repeated expected missing-file errors.
- Artwork downloads have a 120-second resource budget, separate from the six-hour audio budget. Timeout/network disconnection and HTTP 429/5xx can retry twice. Retries preserve the waiting continuation, client key and persistent destination. Cancellation and permanent HTTP failures do not retry. cancelAll drains both system tasks and newly admitted registry retries.
- Continuous media-clock advancement for two seconds admits streaming next-track preparation. Native streaming retains at least five seconds of buffered current audio (or enough for the remainder); local playback can prepare immediately. Buffering, clock stalls, seeks/resets and long observation gaps reset stability. Settings changes use this same admission path.
- An unsuccessful queued handoff keeps its resolved next source until normal play captures it, avoiding a second source negotiation after the grace window. Queue/track/epoch validation remains in normal play.

## Verification

macOS: ArtworkDownloadPolicyTests, BackgroundArtworkQueueTests, PlaybackBufferPolicyTests, GaplessContinuityTests, GaplessPolicyTests, PlayerServiceEngineTests, AuditPlaybackHardeningTests and IsolationAndOfflineRegressionTests. 78 definitions / 88 executions passed, no failures or skips. Final result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_00-41-41-+0900.xcresult`.

Tests include completed inventory without a new download phase/request, actual HTTP 503 retry with the original observer, exhausted retry limits, cancellation/permanent-error policy, stability reset and buffer protection, EOF fallback reusing the next source without a resolver call, existing local engine continuity and account/cache isolation.

iOS Generic Device build succeeded with signing disabled; no simulator used. No warnings or errors in the final build/test logs.

Logs: `/tmp/cassette-cover-prebuffer-verified-tests.log`, `/tmp/cassette-cover-prebuffer-verified-ios.log`.

Physical-device suspended downloads, the user's full cache inventory, and audible subsecond gaps remain unverified. The existing continuity tests measure the engine clock with local PCM fixtures; they do not prove absence of silence in the user's encoded tracks or actual iPhone output.
