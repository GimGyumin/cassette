# Native gapless transition delay

The reported roughly half-second gap can be reproduced with two adjacent 2.5-second
PCM files, without networking or encoder padding. With per-item native audio mix
taps attached, the AVQueuePlayer clock lost about 0.24–0.34 seconds across the
boundary on the development Mac. Preparing the tap earlier and disabling automatic
stall waiting did not eliminate that delay. AudioStreaming's queued PCM path did
not exhibit it.

Native music playback now omits the optional audio-analysis mix when gapless is
enabled. AVQueuePlayer keeps owning the prepared transition; app metadata updates
do not pause, seek, or recreate it. Automatic buffer waiting remains enabled so
real network underruns can recover normally.

This prioritizes audio continuity over the native PCM-driven bar animation: the
bars remain static in this mode. Native analysis remains available when starting
playback with gapless disabled, and for live radio. AudioStreaming's analysis is
unchanged. The native analysis policy is captured when starting playback, and
prepared gapless items always omit the analysis mix. Changing the preference does
not rebuild a currently audible item; its existing tap may affect the first
boundary when gapless is enabled mid-track.

`GaplessContinuityTests` exercises real native and AudioStreaming engines using
uncompressed fixtures. It compares monotonic elapsed time with cumulative media
time across a prepared boundary, excluding cold startup, and rejects losses of
80 ms or more. This measures transport continuity, not acoustic output or a
sample-perfect guarantee for every device, codec, server response or AirPlay route.
`NativePlaybackMeterTests` separately verifies that opt-in native PCM analysis and
seeking still work.

On the focused Mac run of the analysis-policy fix, measured boundary clock loss was about 3.4 ms for
AudioStreaming and 0.02 ms for AVQueuePlayer, with the 80 ms regression limit in
place. The opt-in native meter test also passed. These are development-host clock
measurements, not an iPhone acoustic measurement. The final iOS build request was
declined, so this change has not been compiled for iPhone in this follow-up. The
subsequent live-radio exemption and mid-track preference guards have only had
source-level verification.

Device follow-up: listen to continuous album tracks on iPhone using downloaded
and streamed sources, including the intended Bluetooth/AirPlay route. Keep gapless
enabled before starting the queue. Confirm natural transitions, pause/resume,
manual next and seeking; server-encoded padding still needs source-specific checks.
