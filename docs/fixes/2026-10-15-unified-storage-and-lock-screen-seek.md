# Unified music storage and system seek

## Changes

- Storage uses a native grouped List/Form with an inline navigation title, app usage bar and category legend, automatic-music cleanup recommendation, native size-sort menu and category detail pages. Values describe Cassette data, not fabricated device-wide storage.
- All production audio lives in `Documents/app.cassette/audio`. `CachedTrack` is the single file inventory; `isPinned` protects saved music. `DownloadedTrack` retains denormalized offline library metadata and points to the same asset, rather than owning a separate audio copy.
- Existing Caches audio and Documents downloads migrate into the shared directory before lookup/reporting. Metadata commits before old aliases are retired. Copy failures remain retryable. Legacy extension and M4A migrations now use the shared directory and update the inventory too.
- Download installation adopts the shared inventory and retires the previous automatic file. Automatic writes cannot replace saved music. Clearing automatic storage/FIFO eviction protects pins. Removing a download unpins the asset; the automatic capacity is then enforced. Exact-request identities survive unpinning when audio bytes were not encoded/remuxed, permitting repinning without another media request.
- Storage reports audio once under Music and counts shared physical files once. Cleanup recommendations use only reclaimable automatic audio. Cover reporting includes saved original covers. Logout removes the shared audio directory too.
- A shared mutation lock and short file leases coordinate audio publication and cleanup. Automatic media is excluded from device backup.
- Both system seek paths use the service-owned coalesced command task. Cancellation of the framework caller does not cancel an accepted seek, including zero seconds.
- Periodic clock updates and snapshots without artwork URLs update the retained Now Playing snapshot. Cover refresh uses the current position, rate and timestamp. Rate changes maintain the clock anchor; slow metadata resolution preserves its original timestamp. This prevents old artwork metadata from resetting the system clock while audio continues.

## Validation

Final macOS command selected UnifiedLocalAudioTests, NowPlayingSeekClockTests, LocalSeekSmoothnessTests, PlaybackFailureAndPublicationTests, IsolationAndOfflineRegressionTests, BackgroundDownloadRecoveryTests, OfflineDownloadRoundTripTests, AuditPlaybackHardeningTests, MediaTransferCoordinationTests, SeekAndAACDownloadRegressionTests and PlaybackRecoveryPositionTests.

- 79 test definitions, 94 executions including parameter combinations: passed, 0 failed, 0 skipped.
- Includes legacy file migration, duplicate audio accounting, pin protection, unpin/repin without HTTP, all-download removal, corrupted-cache fallback, cancelled system caller seeking to zero, clock anchors and actual native local AAC seeking to zero while playing/paused for both cached/downloaded sources.
- Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_02-37-19-+0900.xcresult`
- macOS build/test log: `/tmp/cassette-storage-final-tests.log`
- iOS Generic Device build: succeeded, SDK 27.2, code signing disabled. Log: `/tmp/cassette-storage-final-ios.log`.
- No simulators used. No existing tests removed or weakened.

## Device verification outstanding

The layout, Dynamic Type/VoiceOver appearance, iOS 27 actual lock-screen scrub gesture and behavior during device suspension require a physical device. Native macOS audio/clock tests and an iOS compile do not establish that those device interactions have been verified.
