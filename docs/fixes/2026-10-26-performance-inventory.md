# Artwork preparation and playback download reliability

## Changes

- Artwork preparation now inventories directory entries and caches file size, modification date,
  creation date, and validation outcome. Missing/unrelated files do not reach ImageIO; unchanged
  incomplete files are not repeatedly parsed. Changed and replaced originals are revalidated,
  and removed files are evicted from the inventory cache.
- Inventory polling runs every two seconds in normal foreground use and every five seconds
  in background, Low Power Mode, serious thermal pressure, or memory pressure. Worker completion
  still publishes progress immediately; the polling interval does not delay transfers themselves.
- Cancellation propagates into the detached inventory worker, which checks cancellation between
  entries. A transient directory read failure is retried on the next poll.
- Periodic media caching captures playback epoch/source before crossing to MainActor. Automatic
  downloads validate the original epoch before scheduling, after playback establishment, and
  immediately before submitting the transfer. Completed/started transfers retain their normal
  offline behavior; stale preparation cannot initiate a transfer for an obsolete playback epoch.

## Verification

- Added scanner regressions for absent/unrelated files, unchanged invalid/valid files, repair,
  deletion/recreation, same-size replacement, and cancellation.
- Added deterministic performance-budget coverage for inventory polling.
- iOS Simulator app build passed.
- macOS selected regression suites passed: 71 tests / 76 cases including parameterized runs,
  zero failures or skips. Suites cover inventory scanning, performance policy, artwork transfers,
  playback cancellation/hardening, session persistence, and existing performance paths.
- The run initially waited in cache-directory backup metadata access during fixture initialization;
  it subsequently completed successfully without terminating the test process.
- Battery savings require device energy profiling; no percentage improvement is claimed.

The new scanner regression verifies one validation across repeated unchanged polls, instead of
revalidating an incomplete file each time. This is an operation-count check, not an energy benchmark.
