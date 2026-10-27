# Artist-anchored dark transition, build 1012

The requested transition now starts at the artist/information area rather than
partway through the artwork. `FadedArtworkHero` contains the existing information
closure, and a layout anchor identifies its top edge after the complete title.
The background resolves that anchor directly, without storing scroll geometry
in observable state. Multi-line and accessibility-size titles move the start
point with the artist row.

The source artwork and its lower-edge extension retain their brightness above
that boundary. A noninteractive gradient begins transparent at the artist area
and reaches the existing dark canvas below the metadata/transport controls.
A small local text shadow keeps white header text readable without a broad dark
wash. The original artwork is still unmodified and reused from the shared hero
cache. Existing content/actions, image scale, top contrast and navigation remain
on their established paths.

The previous early artwork fade, foreground protection mask and its now-unused
foreground-center analysis were removed. Cached v4 classification, edge colors
and canvas facts remain compatible; decoding ignores the older unused field.

## Files changed

- `Cassette/DesignSystem/Theming/FadedArtworkHero.swift`
- `Cassette/DesignSystem/Theming/ArtworkEdgeAnalysis.swift`
- `Cassette/DesignSystem/CassetteSpacing.swift`
- `Cassette/Views/Browse/AlbumDetailView+Header.swift`
- `CassetteTests/ArtworkPresentationTests.swift`
- `Cassette.xcodeproj/project.pbxproj` (1012)

## Verification

- ArtworkPresentationTests: **TEST SUCCEEDED**, `/tmp/cassette-1012-tests.log`.
- Production rendering checks every sampled edge row above a marked artist
  boundary retains the source brightness, darkening begins below that boundary,
  and the final canvas join stays opaque. The boundary follows long titles and
  accessibility text sizes at 320/390/430 pt. Both artwork treatments retain the
  lower figure without the old early mask.
- Render artifact: `/tmp/cassette-1012-artist-fade.png`. Its blue line is a test
  fixture marking the artist boundary, not application UI.
- iOS generic Simulator build (arm64/x86_64): **BUILD SUCCEEDED**, `/tmp/cassette-1012-ios.log`.
- No compiler warnings/errors in either final log; `git diff --check` passed.

Actual iPhone comparison of the revised transition remains necessary; no device
installation or physical-device visual result is claimed.
