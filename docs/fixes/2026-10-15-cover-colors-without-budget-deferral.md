# Prepare cover colors without budget deferral

The supplied 511-line log contains 303 `palette analysis deferred (device constrained)` entries and one `completed 363/363` entry. The old guard returned success without preparing a palette whenever `allowsHeavyColorAnalysis` was false. Previously downloaded originals also skipped preparation because palette work only ran inside the missing-image download workers.

Changes:

- Removed the resource-budget skip from bulk palette preparation. No changes to unrelated animation/translation budget policies.
- A separate sequential palette pass processes the complete artwork inventory, including already-downloaded originals and alternate track covers. Existing palettes are reused.
- Original files are decoded to at most 240px on a utility task. Exactly one heavy color analysis is awaited at a time. Identical original files share the resulting palette through their physical file identity.
- Separate analyzing-colors state/counters prevent CPU preparation from appearing as continuing image downloads. Account/storage screens display color analysis explicitly.
- Failed analysis is reported as an error rather than a deferred-success result.
- Full palettes are flushed through the persistence queue before preparation completion. Album/cover background mappings remain persisted too.

Regression coverage manually seeds three original IDs containing two unique images, sets the app budget inactive so the old heavy-analysis policy is false, and verifies all colors are generated/persisted with no image HTTP requests. It also verifies identical artwork shares its palette and the transfer/analysis indicators finish.

This removes app-level deferral; operating-system process suspension still controls whether an iOS app can execute while suspended. Physical-device timing and playback/thermal behavior must be checked on device. No simulator is used.

## Final validation

- macOS: 66 test definitions, 109 executions including parameters; all passed, 0 failures, 0 skips. Result summary reports no runtime warnings.
- Suites: ArtworkDownloadPolicyTests, AlbumDetailOfflineTests, ArtworkColorAnalysisTests, BackgroundArtworkQueueTests.
- The constrained-budget regression also uses two Navidrome IDs sharing one content hash, verifying both IDs receive colors even though download identity deduplication collapses them.
- Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_08-15-20-+0900.xcresult`.
- Test log: `/tmp/cassette-colors-final-tests.log`.
- iOS Generic Device build succeeded, SDK 27.2, signing disabled: `/tmp/cassette-colors-final-ios.log`.
- No physical-device thermal/playback performance validation and no simulator execution.
