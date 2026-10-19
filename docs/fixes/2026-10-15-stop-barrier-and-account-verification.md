# Playback stop and account verification

## Playback

Stop now installs an actor-owned barrier before suspension, cancels pending play/seek/restoration work, clears platform interruption/screenshot resume state and resets interruption authority. New play, radio, resume, pause and seek operations cannot supersede cleanup. Signing out rejects new play/resume requests. A resume without a current selection leaves the stopped intent intact. Automatic restore and network recovery respect stopped intent; explicit legacy-session recovery remains available.

Now Playing stop cancels the remote command tail, and queued commands check cancellation after waiting for their predecessor. Playback context is checked around resume's actor hops so a stale request cannot overwrite a newer stop.

## Account UI

- Native two-button confirmation alert: Later / Verify Account. The account identity and server appear in the message; this does not claim to verify an Apple Account.
- Confirm opens a native navigation sheet and grouped Form with a description card and verification action. The existing secure password alert remains an explicit step; credentials continue to use Keychain.
- Account profile card includes the verification row with a red count badge. Account settings also links to the shared detail view.
- Automatic presentation waits five seconds after onboarding, in the active foreground, with initial library presentation finished/deferred and no credential reentry/sign-out pending. Task cancellation resets the pending wait. Each account is prompted once per modifier lifetime/app launch. Account changes or sign-out dismiss pending confirmation.
- Verification checks the captured account/request identity before submitting connection verification and updating saved credentials.

## Files

PlayerService+Controls, +Commit, +Transition, +Radio and +Session; PlayerService; NowPlayingService and +Commands; SubsonicAccountVerificationView; AccountSheetView; AccountSettingsView; Localizable.xcstrings.

## Verification

- Final macOS: 52 tests / 61 executions including parameters; 0 failures, 0 skips, no runtime warnings in result summary.
- Suites: StoppedPlaybackBarrierTests, AuditPlaybackHardeningTests, PlaybackRequestCancellationTests, AccountAndPlaybackRegressionTests, NowPlayingSeekClockTests, PlaybackSessionIdentityTests, PlaybackRecoveryPositionTests.
- New tests suspend stop at metadata cleanup, then issue resume/play/seek/restore/network recovery. They verify no resolve/restart, an empty queue, idle state, released stop barrier, reset interruption state and preserved stopped intent after an empty resume. Sign-out rejects playback requests too.
- A pre-existing gapless fixture lacked a current playback source and therefore could not satisfy the previously added streaming-stability policy with a stationary fake clock. It now explicitly installs the local current source and valid fixture payloads. The original under-one-second preparation check and duplicate-prefetch check are unchanged. No tests were removed or expectations weakened.
- Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.15_03-19-30-+0900.xcresult`.
- Test log: `/tmp/cassette-account-stop-verified-tests.log`.
- iOS Generic Device build: succeeded, SDK 27.2, signing disabled. Log: `/tmp/cassette-account-stop-verified-ios.log`.
- No simulators used. Actual iOS alert appearance, sheet/navigation gestures, foreground five-second timing and device interruption/logout interactions require physical-device verification. No live account password verification was performed by these tests.
