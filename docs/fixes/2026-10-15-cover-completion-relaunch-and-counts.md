# Cover completion after relaunch and accurate completed counts

## Root causes

AlbumCoverPreloadService initialized completion to false on every construction. The old global finished-pass flag could not safely prove that the active account's files still existed. Consequently the UI offered preparation again until server metadata and the entire image inventory had been read.

Bulk progress counted distinct artwork request identities, not unique image files. Opaque per-track IDs can share image bytes. Additionally, missing track artwork could synthesize an album-ID request even though the album cover was already included by the album list.

## Changes

- Account-scoped, hidden completion inventory beside original covers records previously validated file names, sizes, modification dates and device/inode identities in a binary property list.
- Startup restores this inventory immediately after the server account is loaded, before client warmup or cover download. Restoration makes no network requests. Missing/modified files invalidate the saved proof; the existing pass validates and repairs only missing/invalid originals.
- An unchanged inventory skips the expensive whole-directory image/content reconciliation and decoding. A metadata pass still discovers new or changed artwork IDs.
- Completed counts use distinct physical original-image identities after byte-identical covers have been linked by ArtworkContentStore. During work, counters still measure outstanding request identities; completion collapses confirmed identical files to one image.
- Bulk indexing no longer adds a per-track fallback request when a song has an album and no explicit alternate artwork ID. Explicit alternate covers and tracks without an album remain eligible.
- Resetting artwork bookkeeping removes the account's completion inventory. Restoration cannot overwrite an active download and checks the active account again after background file inspection.

No images are merged merely because they belong to one album. Navidrome's content hashes can prove equality before download, but legacy timestamp/opaque IDs cannot. For unknown IDs, a first content fetch can still be needed before byte equality is established. This limitation is documented by the [upstream artwork ID implementation](https://github.com/navidrome/navidrome/blob/master/model/artwork_id.go).

## Added verification

A fixture downloads three artwork IDs containing two unique PNG images, reconstructs the cache/preloader, restores completion without HTTP, runs reconciliation without HTTP, deletes one original and verifies exactly one additional request repairs it. Resetting bookkeeping invalidates the saved completion. An offline persisted-library fixture checks that missing album artwork does not invent a per-track request while explicit alternates and singles remain included.

Physical iOS relaunch/background behavior requires device validation; no simulator is used.

## Final verification

- macOS: 72 test definitions / 79 executions including parameters, 0 failures, 0 skips. Result summary reports no runtime warnings.
- Suites: ArtworkDownloadPolicyTests, AlbumDetailOfflineTests, LibraryCatalogStoreTests, BackgroundArtworkQueueTests and IsolationAndOfflineRegressionTests.
- Completion-persistence failure also has an explicit test: an unwritable record destination must not claim completion; removing the obstruction permits completion without another image request.
- The complete preparation report uses the same unique-image count as the cover state.
- Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_07-57-43-+0900.xcresult`.
- Log: `/tmp/cassette-cover-relaunch-complete-tests.log`.
- iOS Generic Device build: succeeded, SDK 27.2, signing disabled. Log: `/tmp/cassette-cover-relaunch-complete-ios.log`.
- Existing installations have no new file-stamp inventory yet. Their first successful disk reconciliation creates it; later launches restore it without re-reading every original image. Existing valid originals are reused on that initial reconciliation.
- No physical-device visual/relaunch validation was performed and no simulator was used.
