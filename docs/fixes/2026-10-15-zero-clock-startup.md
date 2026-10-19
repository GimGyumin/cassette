# Zero-clock playback startup recovery

The screenshot shows pause intent with elapsed time at 0:00. This is insufficient to identify the failing server response or decoder, but inspection found a recovery coverage gap that can leave this state indefinitely.

## Cause and change

The startup recovery gate accepted only loading/playing. A playing callback followed by waiting can publish buffering before any media time advances; the startup monitor then exited. Sustained-stall recovery rejects progress below 0.25 seconds, so neither recovery path covered this case.

- Keep remote startup recovery eligible for all playback-intent states while progress remains below 0.25 seconds. Preserve pause/error/idle, local-source, transition and track guards.
- Add an independent 45-second startup deadline, so a suspended source refresh cannot hold its own timeout hostage. Keep the current selection and queue and terminate through the existing retryable failure path.
- Monitor local initial playback and successful remote-to-local acquisition switches with the existing 30-second completion deadline.
- Fence completion monitoring and timeout commits against newer transport commands, including same-track pause/resume or interruption.
- The pause icon continues to express playback intent; it is not evidence of audible output. No UI sliders or artwork behavior changed.

## Verification

macOS suites: PlayerServiceEngineTests, AVPlayerEngineTests, AuditPlaybackHardeningTests, PlaybackControlAppearanceTests. 38 test definitions / 41 executions passed; zero failures or skips. Includes zero-clock loading/playing/buffering/recovering deadlines, retained queue/selection, progress, explicit pause, and obsolete-command protection. Updated the previous gate assertion to require recovery for zero-clock buffering/recovering; all existing guard assertions remain.

iOS Generic Device build passed with signing disabled. No simulator used.

Logs: /tmp/cassette-zero-start-final-tests.log and /tmp/cassette-zero-start-ios.log.

The exact screenshot failure was not reproduced against the user's server/device. Audio output, format compatibility for this particular track, and cellular/Wi-Fi behavior still need physical-device verification. The fix closes the demonstrated code-level recovery gap; it does not prove every initial playback failure is resolved.
