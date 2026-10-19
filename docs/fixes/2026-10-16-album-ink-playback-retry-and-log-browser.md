# Album colors, playback retry, and analytics logs

## Album background and foreground

Album detail used a separate perceived-brightness cutoff of 0.72 for white ink,
while the rest of its atmosphere chose black/white by contrast. Medium gray could
therefore show white titles and metadata alongside system chrome using dark ink.
Album detail now follows the atmosphere's contrast decision for its header,
controls, and toolbar appearance.

White sleeves containing a dark subject and side lettering could miss the white
border branch. White-majority borders with two light corners now remain white;
the silver detector additionally requires actual midtone pixels, rather than
the average of black and white regions. A synthetic sleeve regression exercises
the raster analyzer and the page's foreground contrast, without album-name rules.

Palette cache v8 and dominant-color cache v17 replace the earlier analysis results.
User overrides and original artwork files/completion inventories are preserved.
Analysis can reuse those originals without downloading artwork again.

## Playback

`beginSystemInterruption` latched `transport.interrupted`, but explicit resume
returned while that flag remained true, and selecting another track eventually
hit the same engine-start guard. An interruption is not guaranteed to have a
matching end notification ([Apple's interruption guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)).

A new explicit play/resume/station selection clears the old interruption flags
and cancels its deferred hard pause. Automatic queue playback retains the
interruption guard; stop and sign-out barriers still reject new playback.
Terminal failure clears stale seek state and stores a finite retry position,
including zero. Cold resume also applies the ordinary source/codec engine policy,
so a cached MP4 at zero does not fall back to the streaming parser merely because
there is no positive seek offset.

The regression tests omit an interruption-ended event and check that both resume
and selecting another song advance the native media clock. Another test fails
during a pending seek and verifies a retry advances from the retained position.

## Analytics logs

Developer settings now links to Analytics Logs: native grouped file list, inline
title, explanatory text, This Device section, toolbar search and sort, selection,
sharing, deletion confirmation, and a read-only native text viewer. This lists
Cassette's own available process logs, not the inaccessible iOS system diagnostics
shown in the reference screenshot.

Opening or refreshing the browser captures the available current-process OSLog
entries. One file per process is refreshed under Application Support/Cassette/Logs;
up to 20 sessions are retained across launches. Existing export bounds and auth
redaction remain in place; the browser also redacts text when reading archives.
This is a snapshot archive, not a continuous crash recorder. The original direct
Export Logs action remains available.

## Verification

- iOS Generic Device, signing disabled: BUILD SUCCEEDED.
  `/tmp/cassette-recovery-colors-logs-final-ios.log`
- Related macOS suites: PlaybackRecoveryPositionTests,
  PlaybackRequestCancellationTests, StoppedPlaybackBarrierTests,
  PlaybackFailureAndPublicationTests, ArtworkColorAnalysisTests, LogExportTests,
  ArtworkDownloadPolicyTests, AlbumDetailOfflineTests.
  **89 test definitions / 137 executions passed, 0 failed, 0 skipped; no reported
  runtime warnings.** Result:
  `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.16_11-33-20-+0900.xcresult`.
  `/tmp/cassette-recovery-colors-logs-verified-tests.log`
- The cover repair test now waits for the actual completed pass, including color
  analysis, instead of stopping at the earlier `isDownloading = false` transition.
  Its request-count, repaired-image, completion, and reuse assertions remain.
- No simulator was used. Actual iPhone album appearance, native toolbar/search
  placement, real call/Siri interruptions, audio output, and route changes still
  need device verification. Advancing a silent fixture's clock is not a real-device
  listening test.
