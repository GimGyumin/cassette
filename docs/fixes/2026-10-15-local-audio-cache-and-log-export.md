# Local audio cache recovery, shared downloads and developer log export

## Evidence and scope

The supplied execution log contains a startup timeout for Thriller and later native waiting/playing transitions. It does not identify the failed source URL or prove that every failure was a corrupt cache. The pasted analysis is treated as a diagnostic hypothesis, including its corrections that absent artwork files can be expected cache misses and system warnings need independent attribution.

Code inspection found separate local-audio paths: cached lookup checked only file size, cached imports did not share the download validation pipeline, and cached M4A could reach a streaming parser requiring faststart layout. Cached decode/startup failures had no reliable one-time eviction/recovery path. Completed cache transfer reuse existed only in a small in-memory coordinator.

## Implementation

- LocalAudioFileStore supplies common transport/container validation and atomic file publication. Both cache and downloads reject empty/size-mismatched, structured error, explicitly non-audio and malformed MP4-container payloads through AudioResponseValidator. These checks are not a full decode of every format. Runtime decoder failures are handled separately.
- Cache imports validate staged bytes before replacing an existing good cache. Lookup also validates older entries, so same-sized XML/JSON error bodies no longer count as valid audio.
- Cached sources use the native local engine on iOS, which handles M4A without the streaming parser's faststart requirement. Permanent downloads retain their existing encoding/spatial routing behavior.
- A cached startup timeout, decode failure or grossly premature EOF evicts only the failed cache file, retains the selected song/queue/position, and resolves one replacement. Parsed duration takes precedence over potentially incorrect catalog duration for EOF detection. Source resolution and resumed playback are bounded; a terminal or newer command prevents late recovery from restarting playback.
- File-scoped eviction includes account and path checks, handling renamed remote IDs without removing another account's cache. Explicit async implementations ensure protocol defaults do not bypass the actor's file-scoped removal.
- CachedTrack gains optional encoded MediaTransferKey metadata. File and request provenance are committed together. DownloadService consults it after service recreation, requiring the same account revision and complete byte-producing request (format, bitrate, range/offset and headers).
- Completed immutable transfers can be hard-linked through staging and final download publication. Cache clearing/eviction only removes its own reference; a permanent pin remains. Shared inodes are counted under Downloads rather than double-counted as playback cache.
- Legacy cache entries without request provenance remain available for playback after validation; they are not blindly promoted as a requested original/lossy format. Re-encoding/remuxing can produce a different file, so those transformed bytes do not share physical storage with the source.

## Developer settings

Settings → Developer → Export Logs creates a UTF-8 text file and presents the iOS system share sheet. macOS exposes Share Logs after creation. English and Korean labels are included.

Export uses Apple's [OSLogStore](https://developer.apple.com/documentation/oslog/oslogstore), scoped to the [current process](https://developer.apple.com/documentation/oslog/oslogstore/scope/currentprocessidentifier), with available entries from the preceding 24 hours and a 5 MB cap. It does not claim to retrieve previous app-process logs or every Xcode stdout/system-console message. URL authentication/query values, Basic/Bearer tokens and common credential fields are redacted; playback format diagnostics are retained. Export files are removed after the iOS share sheet closes.

## Verification

macOS suites: UnifiedLocalAudioTests, LogExportTests, CacheServiceServerIsolationTests, MediaTransferCoordinationTests, AudioResponseValidatorTests, AuditPlaybackHardeningTests, IsolationAndOfflineRegressionTests, AlbumDetailOfflineTests.

87 test definitions / 95 executions passed, zero failures/skips/runtime warnings. The suite exercises actual imported M4A playback on AVPlayer, no-network cache-to-download promotion, shared-inode storage, cache clear preserving a download, format mismatch, same-sized corrupt cache removal, renamed IDs/account boundaries, one-time recovery, truncated EOF versus incorrect catalog duration, log creation and credential redaction.

An existing preparation test asserted that metadata inventory was already a download. Its phase assertions now require resolving inventory and no downloading; the original service-owned continuation, joining, request-count and completion checks remain intact. The renamed-ID test exposed async protocol default dispatch; explicit async actor methods fixed it without relaxing its assertion. A missing test-only AudioStreaming import was also corrected.

iOS Generic Device build succeeded with signing disabled. No simulator used; no warnings/errors in final build/test logs.

Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_01-23-44-+0900.xcresult`.
Logs: `/tmp/cassette-local-audio-final-tests.log`, `/tmp/cassette-local-audio-final-ios.log`.

Physical iPhone playback of the reported tracks, share-sheet appearance, app-upgrade migration of the existing SwiftData store, and background suspension remain unverified. This does not classify every pasted system warning as an app fault or claim all playback failures are solved.
