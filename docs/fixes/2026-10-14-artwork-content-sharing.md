# Artwork content sharing

Identical original bytes with unrelated remote IDs previously occupied separate files. Legacy and current cache names could also coexist. Server-provided image hashes still avoid duplicate requests when available; the new local content store additionally shares bytes after download.

## Implementation

- `ArtworkContentStore` hashes bytes with SHA-256, verifies the source bytes, and atomically installs a hard link. Each public cover path remains usable. Replacing one cover uses atomic replacement; deleting one name leaves other references intact.
- Foreground persistence, standalone offline cover downloads, and background URLSession installation use the same serialized content store.
- At cover inventory preparation, a utility worker reconciles valid existing artwork (including legacy names). It runs once per directory per process; only one image is read at a time. No network is required for this migration. Existing names are retained for offline metadata compatibility, but identical bytes share storage.
- Cached paths are rechecked before reuse; deleted or replaced sources do not count as valid matches. Canonical directory paths avoid differences between filesystem enumeration and symlinked temporary paths.
- Storage totals count each device/inode pair once within a category directory, rather than counting every hard link.

## Boundaries

- If a server supplies unrelated IDs without a content hash, an initial request for each unknown ID is necessary to compare its bytes. This change does not claim to eliminate that first network transfer.
- Equality means identical file bytes. Visually identical images with different encoding or metadata are not merged. Resized derivatives remain distinct when their bytes differ; original quality is preserved.
- External artist-image caches are not migrated by the album-cover inventory. The storage category still includes those images.
- Reconciliation occurs when a cover preparation/inventory pass runs. This does not directly clean files on a connected physical device during development.

## Verification

- macOS: ArtworkDownloadPolicyTests, BackgroundArtworkQueueTests, IsolationAndOfflineRegressionTests — 28 test definitions / 33 executions passed, zero failures or skips.
- The first run exposed a canonical-path mismatch when reusing migrated files. Fixed path normalization and reran all three suites successfully without weakening assertions.
- Coverage includes distinct opaque IDs sharing an inode, alternate image preservation, replacing/removing one alias, cache clearing and retry, legacy migration, and actual URLSession delegate installation sharing bytes.
- iOS Generic Device build succeeded, signing disabled; no simulator used.
- Logs: `/tmp/cassette-content-sharing-final-tests.log`, `/tmp/cassette-content-sharing-final-ios.log`.
- Physical-device storage reduction, iOS suspension/relaunch behavior, and migration performance against the reported 2 GB cache remain unverified.
