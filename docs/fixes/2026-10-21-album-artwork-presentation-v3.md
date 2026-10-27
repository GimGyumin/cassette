# Album artwork presentation, build 1008

## Cause and change

The previous full-width header kept the title below an unmasked square and used the
legacy representative palette as the entire page background. Fine texture could
also be averaged away by the 64 px edge analysis. A silver sleeve consequently
ended at a visible boundary above a bright gray page.

Prepared image facts now select three presentations without album-name rules:

- **Uniform**: opaque, near-solid edges (including a strict 3/255 channel tolerance
  for at least 90% of border samples). Preserve the whole square and extend its
  exact sRGB edge color. No fade, rounding or shadow.
- **Faded**: opaque texture or smooth gradients with coherent local edge medians.
  Composite a noninteractive gradient beginning at 44% of the hero into a neutral
  0.18 sRGB charcoal content canvas. Put the single white title over its lower
  portion; artist, metadata, controls and tracks continue on that same canvas.
- **Standard**: complex edges, transparency, missing/currently outdated analysis,
  or an explicit Cover Card preference. Retain the inset header.

Analysis uses a bounded 192 px raster from the existing preparation thumbnail.
Border patches use medians to ignore fine grain; abrupt adjacent changes above
32/255 select Standard. This is a heuristic, not an identification of specific
albums or a reconstruction of Apple's internal classifier. Full-Width Artwork
can still override a conservative Standard classification for opaque covers.

The v3 analysis is persisted with the existing account/artwork-scoped palette.
Older records decode and are refreshed by app/library preparation. Album views
read prepared facts; neither opening nor scrolling performs pixel analysis.
The legacy representative palette is retained for other surfaces. The album's
edge color, content canvas, semantic text palette and control fill are separate.
Only this page's chrome follows its contrast policy; the app appearance setting
is not changed.

## Layout and resolution

`FadedArtworkHero` lays out the title as real content instead of overlaying a
fixed-height text box. Long titles and Dynamic Type extend the canvas while the
artwork remains square at the container width. The gradient reaches the exact
canvas color by the artwork's bottom. Uniform sleeves retain bottom-edge figures.
The existing album page, track/actions bindings, navigation route, source zoom,
mini-player and tab container are reused.

Both full-width heroes request the existing 1200 px hero tier. `CoverArtView`
continues a permitted hero request after painting a thumbnail; previously an
initial/thumbnail image could cause an early return before that upgrade.
Original local files, network restrictions, request coalescing and cancellation
continue to be handled by `ArtworkImageCache`.

## Files changed in this revision

- `Cassette/DesignSystem/Theming/ArtworkEdgeAnalysis.swift`
- `Cassette/DesignSystem/Theming/FadedArtworkHero.swift` (new)
- `Cassette/DesignSystem/CassetteSpacing.swift`
- `Cassette/Views/Browse/AlbumDetailView.swift`
- `Cassette/Views/Browse/AlbumDetailView+Header.swift`
- `Cassette/Views/Browse/AlbumDetailView+Layout.swift`
- `Cassette/Views/Browse/AlbumDetailView+Actions.swift`
- `Cassette/Views/Browse/CoverArtView.swift`
- `CassetteTests/ArtworkPresentationTests.swift`
- `Cassette.xcodeproj/project.pbxproj` (1008)

## Validation

- iOS Simulator generic build (arm64 and x86_64): **BUILD SUCCEEDED**,
  `/tmp/cassette-1008-ios.log`.
- Native macOS build and targeted suites: **TEST SUCCEEDED**,
  `/tmp/cassette-1008-final-tests.log`. Suites: ArtworkPresentationTests,
  AlbumDetailOfflineTests, ArtworkColorAnalysisTests, ArtworkDownloadPolicyTests,
  ArtworkMemoryTests.
- No compiler warnings/errors in either final log; `git diff --check` passed.
- A first render assertion sampled the fractional transparent last bitmap scanline.
  The corrected test renders the real opaque page continuation and checks all
  scanlines across the hero/canvas boundary; it passes at every tested width.

Production hero rendering is checked at
320, 390 and 430 pt, including a long accessibility-size title. Synthetic fixtures
cover solid edges, compression noise, silver grain, gradients, busy edges and
transparency; old persisted facts and account replacement remain covered.

Device follow-up: compare the actual server originals of Thriller 40, This Is It,
The Ultimate Collection and Dangerous, since fixture tests cannot guarantee the
classification of every cover revision. Verify status-bar/glass contrast, rapid
zoom/back and interrupted back gestures, scroll, playback, downloads, and the
persistent mini-player on an iPhone. No simulator runtime/device UI run is claimed.
