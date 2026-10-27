# Smooth album artwork and top contrast, build 1011

The user's second screenshot is Apple Music; the first is Cassette. In the
This Is It comparison, the heading position is already close, but Cassette's
artwork starts lower, the full-length figure fades too early, its canvas is
neutral rather than subtly artwork-tinted, and light status text is used over a
light top edge.

## Implementation

- ArtworkEdgeAnalysis v4 adds persisted smooth/textured treatment, top-edge
  color, an independent dark content canvas and a foreground center estimate.
  Adjacent border variation distinguishes fine grain from smooth gradients.
  For smooth sleeves, central pixels are compared with the row's interpolated
  edge colors to find a foreground center. These are bounded heuristics, not
  album-name rules, object recognition or Apple metadata.
- Smooth artwork uses a 12%-width upper extension instead of the texture mode's
  22%. The heading stays at its existing width-relative anchor, so the figure
  moves upward without moving the title or stretching the main square.
- The surrounding background keeps a broad lower fade. A feathered elliptical
  cutout protects the estimated figure's center; a separate gentle late fade
  completes the figure's transition before the title. The cutout uses a grouped
  destination-out mask so its alpha is resolved before masking the background
  gradient. No effects are baked into the cached original artwork.
- Content canvas RGB is independent of the raw edge RGB. Neutral edges keep a
  neutral charcoal; colored lower edges contribute a bounded hue to a dark
  canvas. Semantic text and controls continue to derive contrast from that
  canvas.
- Status-bar/navigation appearance follows cached top-edge luminance at the
  top, then the content scheme after scrolling. Page content and the parent
  mini-player retain their independent appearance policy. SwiftUI's native
  toolbar scheme and the existing UIKit status bridge receive the top scheme.
- Preparation owns the additional pixel work. Cache facts are persisted and
  used without analysis during navigation/scrolling. V3 classification remains
  usable while preparation upgrades facts to v4, avoiding an interim Card mode.
- Uniform sleeves and complex Standard cards retain their existing rendering.
  Server titles, genre, quality labels, track order and playback bindings are
  preserved; differences in the two services' metadata are not rewritten to
  imitate the reference.

## Actual files changed in this revision

- `Cassette/DesignSystem/Theming/ArtworkEdgeAnalysis.swift`
- `Cassette/DesignSystem/Theming/FadedArtworkHero.swift`
- `Cassette/DesignSystem/CassetteSpacing.swift`
- `Cassette/DesignSystem/Components/StatusBarScrim.swift`
- `Cassette/Views/Browse/AlbumDetailView.swift`
- `Cassette/Views/Browse/AlbumDetailView+Header.swift`
- `CassetteTests/ArtworkPresentationTests.swift`
- `Cassette.xcodeproj/project.pbxproj` (1011)
- This report

## Validation

- iOS generic Simulator build, arm64 and x86_64: **BUILD SUCCEEDED**,
  `/tmp/cassette-1011-verified-ios.log`.
- Native macOS app/test build and integrated ArtworkPresentationTests,
  ArtworkColorAnalysisTests and ArtworkDownloadPolicyTests: **TEST SUCCEEDED**,
  `/tmp/cassette-1011-verified-tests.log`.
- No warnings/errors in either final log. `git diff --check` passed.

Production rendering compares the smooth and textured policies with the same
full-length colored figure: the smooth figure starts 10%-width higher, its lower
body stays visible, the title position stays fixed and the canvas join is opaque.
Synthetic rendering is inspected in `/tmp/cassette-1011-smooth-hero.png` and
`/tmp/cassette-1011-textured-hero.png`. Existing tests cover 320/390/430 pt and long
accessibility titles, uniform sleeves, texture/gradient classification, legacy
JSON migration, account/artwork invalidation and download policy.

The first color fixture was authored in CGContext's bottom-left coordinates;
its gradient was corrected so its displayed upper edge is the bright edge being
asserted. A render test also caught an ungrouped mask that failed to protect the
figure; it passed after the destination-out composition fix.

Actual iPhone comparison remains necessary for the exact This Is It/Thriller 40
server originals, system status/navigation appearance, interrupted zoom/back,
scroll and persistent playback surfaces. The subject estimate is conservative
and can be less suitable for off-center or unusually shaped figures; manual
Cover Card presentation remains available. No physical-device visual result is
claimed.
