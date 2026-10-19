# Completed artwork deleted by startup cleanup

## Cause missed by the earlier relaunch fix

Cold startup runs `runCoverArtGarbageCollection`. Its reference set includes downloaded albums, downloaded tracks/playlists and Home pins, but not the complete library's bulk artwork. `DownloadService.garbageCollectOrphanedCovers` therefore deleted active-account originals absent from that partial reference set. Restoring the new completion inventory before startup cleanup did not prevent those files from subsequently disappearing and being queued again.

A second startup path, `invalidateCoverArtCacheIfNeeded`, removed the entire artwork directory on a decode-format version change, including verified originals and their completion inventory.

## Fix

- Normal account garbage collection preserves `@original-v1` library artwork. Partial offline/pin references cannot prove library originals orphaned. Explicit storage cleanup and logout retain their removal behavior.
- Decode-format migration invalidates only resized `@thumb` and `@hero` derivatives. Original, legacy offline artwork and completion records survive.
- A successful cover pass clears its downloading flag before publishing completion.
- Restoring validated completion clears transfer/error state and publishes a terminal shared preparation snapshot, allowing the library progress/Live Activity to finish.
- The account status copy describes cover downloading only while covers are actually incomplete and downloading; local indexing alone uses the search-preparation copy.

## Regression verification

A fixture completes two bulk originals without any saved audio/pins, runs format invalidation and startup GC with an empty reference set, recreates the preloader and restores completion. It verifies originals/bookkeeping survive, derivatives are removed, shared preparation transitions from covers to complete, downloading is false and no additional image HTTP request occurs. Explicit logout then removes the originals and invalidates restoration.

Final macOS: 65 test definitions, 71 executions including parameters; 0 failures, 0 skips. Result summary reports no runtime warnings.

Suites: ArtworkDownloadPolicyTests, IsolationAndOfflineRegressionTests, BackgroundArtworkQueueTests, AlbumDetailOfflineTests.

Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_08-04-45-+0900.xcresult`.
Test log: `/tmp/cassette-cover-startup-final-tests.log`.
iOS Generic Device build succeeded (SDK 27.2, signing disabled): `/tmp/cassette-cover-startup-final-ios.log`.

No simulators used. Actual iOS relaunch/Live Activity appearance requires device verification. Files already deleted by earlier app versions must be fetched once again; this change prevents the ordinary startup paths from deleting those originals again.
