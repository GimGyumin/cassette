# Album full-bleed follow-up, build 1009

## Screenshot findings

The new device screenshot confirms that build 1008's Faded path is active:
white text, dark canvas and lower artwork fade are present. The remaining
mismatch is composition. The square starts at the screen top, putting the
portrait behind navigation and placing the large title too high. The wide play
button and an album-description preview also change the transition to tracks.

## Changes

- `FadedArtworkHero.swift`: extend a narrow upper strip of the existing hero
  above the square by 22% of the current container width. Blend its join over
  4% of the width. The main square keeps its original scale and full width,
  while its subject moves below floating chrome. No image analysis is added.
- Keep the noninteractive lower gradient beginning around 40–44% of the square
  (responsive to the visible title footprint);
  increase its middle/lower coverage so lower sleeve typography recedes.
  The fade reaches the exact dark content canvas at the visible hero bottom.
- Place one layout-sized white title at the lower artwork area. Use a Dynamic
  Type title2 bold token and let long/accessibility titles grow the hero.
- Tighten the artist/metadata/controls gaps. Faded transport circles are 52 pt
  and the play capsule is capped at 160 pt; constrained widths can shrink it.
- Move the Faded album-description preview after the track/footer area. Its
  existing sheet, text and accessibility behavior remain accessible.
- Account-scoped v3 classification, Uniform edge color and uncropped sleeves,
  Standard cards, image-resolution policy, existing navigation/zoom and parent
  playback surfaces continue through their existing implementations.

These proportions are informed by the supplied screenshots. They are not
measurements of Apple's internal implementation.

## Actual files changed in this revision

- `Cassette/DesignSystem/Theming/FadedArtworkHero.swift`
- `Cassette/DesignSystem/CassetteSpacing.swift`
- `Cassette/DesignSystem/CassetteTypography.swift`
- `Cassette/Views/Browse/AlbumDetailView.swift`
- `Cassette/Views/Browse/AlbumDetailView+Header.swift`
- `Cassette/Views/Browse/AlbumDetailView+Layout.swift`
- `CassetteTests/ArtworkPresentationTests.swift`
- `Cassette.xcodeproj/project.pbxproj` (1009)
- This report

## Verification

- iOS generic Simulator build, arm64 and x86_64: **BUILD SUCCEEDED**,
  `/tmp/cassette-1009-ios.log`.
- Native macOS app/test build and targeted regression suites: **TEST SUCCEEDED**,
  `/tmp/cassette-1009-tests.log`.
- Suites: ArtworkPresentationTests, AlbumDetailOfflineTests,
  ArtworkColorAnalysisTests, ArtworkDownloadPolicyTests.
- No compiler warnings/errors in the final logs. `git diff --check` passed.
- Inspected production render artifacts:
  `/tmp/cassette-1009-faded-hero.png` and
  `/tmp/cassette-1009-subject-hero.png`.

The production hero render checks the upper
edge and opaque canvas join at 320/390/430 pt and long accessibility titles. A
new colored subject fixture verifies that the main artwork moves below chrome
at its original scale rather than being enlarged/cropped or darkened early.
Classification fixtures retain solid white/color sleeves, texture, gradients,
complex edges and transparency checks; cache/version/account/offline and artwork
network policy regressions are included.

Actual-device follow-up is still needed for the exact server artwork versions,
status bar and Liquid Glass appearance, scrolling, zoom/back cancellation,
playback/download controls and persistent mini-player. No iPhone install or
interactive simulator run is claimed.
