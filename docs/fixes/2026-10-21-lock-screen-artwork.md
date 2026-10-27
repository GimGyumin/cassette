# Lock screen artwork, build 1010

## Findings

Cassette already publishes album artwork and transport controls through
`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`. Two paths weakened that
integration:

1. `displayArtwork` accepted a local 240 px thumbnail as its final result and
   returned without requesting the 1200 px hero. The explicit snapshot fallback
   URL was also limited to 600 px.
2. iOS 27 additionally created a typed NowPlaying `MediaSession` while continuing
   to publish legacy MediaPlayer metadata and register legacy commands. Apple
   explicitly advises against combining those APIs for local playback:
   https://developer.apple.com/documentation/nowplaying

## Changes

- Keep one MediaPlayer owner for system metadata and remote commands. Replace
  the competing `CassetteMediaSessionController` with
  `CassetteNowPlayingEntityPublisher`, which only donates Siri current-song
  relevance through AppIntents. It creates no playback session or commands.
- Keep permanent originals and local hero-tier cache hits first. If only a
  thumbnail exists, publish it immediately and continue the authenticated hero
  cache request. The existing cache's hero decode limit is 1200 px.
- Raise the fallback cover URL's requested size from 600 to the hero tier size.
- Pass the original image through `MPMediaItemArtwork`; no album-page gradients,
  crop, blur, typography or controls are baked into the artwork.
- Merge late artwork into the latest metadata dictionary, preserving elapsed
  position and rate. Keep generation/item checks so an outgoing track cannot
  replace the next track's artwork. A late preview cannot downgrade a larger
  current artwork.
- Coalesce an artwork resolution per track generation, including its preview
  and upgrade, so progress/pause publications do not launch another upgrade.
- Permit bounded retry even when a preview is already visible. Re-publishing
  the preview does not reset the retry counter. The URL fallback now respects
  the same offline/cellular policy as the shared artwork cache.

`MPMediaItemArtwork` documentation:
https://developer.apple.com/documentation/mediaplayer/mpmediaitemartwork

## Actual files changed

- `Cassette/Services/Implementations/NowPlayingService.swift`
- `Cassette/Services/Implementations/NowPlayingService+Artwork.swift`
- `Cassette/Services/Implementations/NowPlayingService+Commands.swift`
- `Cassette/Services/Implementations/NowPlayingService+Update.swift`
- `Cassette/Services/Implementations/PlayerService+Artwork.swift`
- Removed `Cassette/Services/Playback/CassetteMediaSessionController.swift`
- Added `Cassette/Services/Playback/CassetteNowPlayingEntityPublisher.swift`
- `CassetteTests/AlbumDetailOfflineTests.swift`
- `Cassette.xcodeproj/project.pbxproj` (1010)

## Validation

- macOS app/test build and artwork suites: **TEST SUCCEEDED**,
  `/tmp/cassette-1010-artwork-tests.log` (6 tests).
- Existing system seek/clock suite: **TEST SUCCEEDED**,
  `/tmp/cassette-1010-clock-tests.log` (3 tests).
- No warnings/errors in all three final logs; `git diff --check` passed.
- iOS generic Simulator build, arm64 and x86_64: **BUILD SUCCEEDED**,
  `/tmp/cassette-1010-ios.log`.

Added deterministic tests with a held URLProtocol response:

- A 240 px cached thumbnail is visible before the hero request is released.
- The published result and requested artwork image are 1200 px.
- A 37-second paused clock remains intact when the hero finishes.
- Pause/resume retains the same published artwork object.
- An outgoing track's late response cannot replace the next track's metadata.
- Cellular mode keeps the preview, performs no hero request and preserves the
  bounded retry counter across repeated preview reads.

The expanded Lock Screen presentation is controlled by iOS and user interaction.
Cassette supplies ordinary high-quality metadata/artwork rather than constructing
or forcing that screen. Actual iPhone verification of tapping the cover,
background auto-advance and remote gestures is still required; no physical-device
UI result or installation is claimed.
