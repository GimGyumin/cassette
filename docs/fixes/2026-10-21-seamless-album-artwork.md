# Build 1006 — Seamless album artwork

## Result

Compact album detail pages can extend an opaque, uniformly colored sleeve to the
full page width and behind the status/navigation bar. The full image fits inside
a square; it has no rounded corners, border, shadow, crop, or bottom fade. Its
measured sRGB median edge color fills the page exactly, including near-white sleeves.
A narrow figure reaching the bottom therefore stays visible. Album information is
centered below the artwork, followed by the existing shuffle/play/download controls
and track list. Black/white primary ink and contrast-adjusted secondary text derive
from the same canvas color; the quality label keeps opaque primary ink.

This follows the attached confirmed A policy: automatically use seamless layout only
for confident uniform sleeves. Complex artwork retains the inset card. The album's
More menu offers Automatic / Full-Width Artwork / Cover Card. Transparent artwork
cannot be forced into the opaque full-width mode. Choices persist by account/album
and reset with the app settings. macOS and regular-width iPad keep the two-column
layout. All playback, download, sharing, queue, and favorite actions use their existing
implementations.

## Analysis and caching

`ArtworkEdgeAnalyzer` examines a bounded 64×64 sRGB raster off the main thread:

- Samples 1–3 pixel inset bands on each side and their four corners.
- Uses RGB channel medians with an 18-level tolerance.
- Requires at least 90% matches (92% for very bright whites), 80% per side, three
  matching corners, and opaque pixels throughout the image.
- Stores uniformity, the exact edge color, algorithm version, and an FNV-1a pixel
  fingerprint. No artist/album name exceptions are used.

These are conservative Cassette heuristics, not Apple implementation values.

`ArtworkPalette` persists the optional edge facts in the existing palette cache;
older records decode without them and are backfilled. `ArtworkImageCache` warms
preparation as source thumbnails load, coalesces concurrent consumers, and allows
album pages to join pending work. Scoped keys include the server identity, a hash
of the server/user pair, and the content-versioned artwork identity. Legacy palette
colors are reused only when their pixel fingerprint matches the current image.
Original replacement and cover invalidation discard the old facts. Generation and
per-cover revision checks prevent old preparation tasks from overwriting a replacement.
Warm analysis is serialized through a cancellation-aware gate. PerformanceGovernor
permits heavy clustering only when the device budget allows; otherwise the inexpensive
edge facts remain available with a provisional border-color palette for complex sleeves.
A subsequent eligible preparation refines that provisional palette. No image analysis
is started in body or scroll callbacks. Cache persistence retains
short memory locks and writes snapshots outside them.

## Navigation and chrome

The existing native album zoom routes remain in the owning NavigationStack. The mini
player and tab bar remain in the parent. The system back button and share/more toolbar
stay above the cover; modern iOS supplies the toolbar's grouped Liquid Glass. At the
top, the navigation background is transparent; after the hero scrolls away, system
bar handling resumes. Scroll state publishes only a boundary crossing rather than
invalidating the entire page on every frame. A cover or palette load never hides the
whole page behind an opaque loading overlay.

Official API references:
- [ignoresSafeArea](https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:))
- [Toolbar background visibility](https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:))
- [System toolbar glass grouping](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))

## Verification

Regression coverage includes uniform white/black/beige/gray/blue sleeves, minor white
noise, gradients, broad edge subjects, a narrow figure touching the bottom, transparency,
exact edge-color preservation, text contrast, old/new cache encoding, scoped accounts,
cover replacement, persisted/reset manual choices, and removal persistence. Existing
palette-lock, memory, color, and album offline regressions are also exercised.

A production `SeamlessArtworkHero` rendered at 390 points is exported to
`/tmp/cassette-1006-seamless-hero.png`. Pixel checks confirm square corners use the
exact sleeve background and the figure at the bottom remains present. This image is
a synthetic component fixture, not an Apple Music screenshot or a device capture.

iOS and native macOS compilation passed without warnings. The final focused
regression run passed 112 executions with zero failures, including the constrained-budget
palette fallback. Universal macOS build results are recorded separately.

Final build/test logs:
- `/tmp/cassette-1006-final-ios.log`
- `/tmp/cassette-1006-final-tests.log`
- `/tmp/cassette-1006-final-mac.log`

No usable iOS Simulator runtime is installed on this Mac. Native iPhone navigation,
interactive cancellation, status-bar overlap, and a visual comparison with the actual
Michael Jackson artwork still require on-device verification. No exact reproduction
of Apple's private animation timing is claimed.
