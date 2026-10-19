# Artwork-driven player and lyrics background

## Existing structure retained

`FullPlayerView` puts one `AppleMusicLyricsBackground` behind both ordinary player and live
lyrics content; changing lyric lines does not construct another background. The macOS full
player and lyrics sidebar use the same component. Playback, translation, scrolling, chrome,
sliders and gestures remain outside the renderer.

`FullPlayerViewModel` still obtains images from the existing RAM/disk/server-scoped
`ArtworkImageCache` (240px thumbnail / 1200px hero). `AlbumColorAnalyzer` still performs its
border classification, perceptual clustering and text-contrast selection. The existing
`DominantColorExtractor` / persisted `ColorCache` supply the fallback and UI palette. No
palette-cache keys or album-specific colors were changed.

The old artwork renderer already used MTKView and Metal Performance Shaders, rather than a
MeshGradient, Canvas, Core Image or SwiftUI layerEffect. Its problematic steps were 1.85×
saturation with per-channel clipping before blur, gamma-encoded artwork sampled as linear,
and a 0.52-to-0.34 multiplier that excessively darkened the bottom. The fallback also
boosted saturation and darkened the already-remapped palette.

## Rendering pipeline

1. `ArtworkSceneTextureCache` shares preparation by source image identity and Metal device.
   Up to six 512px textures (~6 MiB total) are retained. A weak image identity prevents the
   texture cache from retaining full-size hero images or confusing reused object addresses.
   Concurrent requests share a utility-priority worker; cancellation removes subscribers
   and cancels work when the last subscriber leaves. Memory pressure clears cached entries.
2. Core Graphics color-converts the cover to Display P3. Premultiplied encoded channels are
   unassociated before uploading to an sRGB-transfer texture. Display P3 uses this same
   transfer function; GPU samples therefore decode to **linear P3**, not linear sRGB.
   At most 32×32 samples produce an alpha-weighted mean, luminance percentiles and saturation
   once during preparation. This is lightweight scene metering, not repeated palette clustering.
3. The scene shader samples the actual artwork four times at widths 125%, 80%, 50%, 25%.
   Distinct centers, rotation speeds and orbits distribute color throughout the surface.
   Two smooth noise evaluations warp the domain; a localized quadratic twist adds fluidity.
   Weighted blending and adaptive diffusion of a chroma-weighted artwork anchor soften subject shadows
   without averaging colored regions into neutral faces or lettering. The ordinary mean is
   retained separately for luminance adaptation and transparent-pixel compositing.
4. One reusable GPU Gaussian blur (sigma 24 at the low-resolution target) follows composition.
   No full-resolution blur or per-frame CPU image work is involved.
5. Saturation is adjusted gently **after** blur. Uniform chroma limiting preserves hue.
   A smooth, artwork-adaptive luminance shoulder retains readable white lyrics. Following the
   latest supplied device screenshot, chromatic/contrasting covers receive a broad continuous
   top-to-bottom exposure curve before tone mapping. Neutral and very dark covers retain their
   tone; there is no black overlay or abrupt shadow clipping. A 4% edge vignette remains. Intermediate RGBA16Float textures
   keep blending and blur in linear P3. The P3-tagged sRGB-transfer drawable encodes once.
   Stationary sub-LSB dither in the presentation pass reduces banding.

Constants control geometry/tone globally; no Xscape-specific golden/olive RGB values exist.
The static fallback uses reduced saturation and a lighter overlay if Metal is unavailable.

## Animation and resource budget

- At most 384px on the longest side, aspect-preserving, 15 FPS. Only the background upscales.
- Two command buffers may be in flight. Saturation skips a frame instead of blocking audio/UI.
- Pipelines and the blur kernel are prepared on a worker. Render targets are reused until resize.
- Slow continuous analytic motion has no manually reset loop boundaries. A monotonic decorative
  clock freezes during pause, hidden/inactive scenes and constrained performance states.
- Album changes fade over 1.2 seconds. Interrupted fades snapshot the displayed mixture.
  A separate fade clock allows a bounded transition while playback is paused, without moving
  the artwork. Hiding freezes both clocks; Reduce Motion / Low Power / memory and thermal
  constraints disable motion and fades. The view stops its display link and cancels artwork
  preparation when inactive/hidden, and releases per-view GPU resources on dismantling.
- No audio meter, playback-position or lyric-progress subscription exists in the renderer.

## References and implementation choice

[WWDC26 — Compose advanced graphics effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/322/)
shows an example podcast background with blurred artwork, shader-driven domain warping and a
separate time input. It does not disclose Apple Music's private native implementation.
[Web background reverse engineering](https://www.aadishv.dev/music) informs the four cover sizes,
independent movements and twist concept; its web saturation settings are not treated as native
iOS constants. MTKView/MPS was retained over replacing the renderer with SwiftUI Shader +
TimelineView because it already provides explicitly bounded drawable resolution, GPU blur,
frame scheduling and in-flight backpressure without updating the SwiftUI tree each frame.

## Validation

`ArtworkSceneTests` exercises real Metal rendering, deterministic frames, motion without audio,
interrupted crossfades, neutral dark/mid/white covers, alpha-aware statistics, sRGB-transfer
texture uploads, same-image concurrent cache reuse, cancellation, and paused/hidden clocks.
PNG readback is test-only and encodes linear P3 correctly. The optional real-art preview reads
`/tmp/cassette-xscape-cover.jpg`; that copyright artwork is not committed to the project.
Lyric timing/seek/scroll, chrome and performance-budget tests are selected alongside it.

Verification on 2026-10-08: the final unsigned generic iOS build succeeded. 42 selected test
executions passed, including actual Metal output,
shared texture-cache behavior, dark/mid/white covers, lyric seek/timing/scroll and performance
budgets. Xscape Deluxe production-renderer PNGs at 0, 30 and 90 seconds were exported and
visually inspected. These are background-only macOS GPU outputs, not full-screen iPhone UI
screenshots or a same-device Apple Music comparison. The test target's previously added HTTP
seek recorder needed a minimal actor-conformance correction to compile; playback code was
not changed for this background refinement. Existing audio actor-isolation warnings remain;
no background Swift or Metal build warnings/errors were reported.

Logs: `/tmp/cassette-background-refinement-tests.log`,
`/tmp/cassette-background-refinement-ios.log`. Physical iPhone comparison against Apple Music,
frame-time profiling, HDR behavior and battery measurements remain separate device checks.
Apple's private native tone mapping/geometry is unknown; this is a visually informed renderer,
not a claim of identical implementation or pixel-perfect matching.

## Latest device-reference correction

The user's new Apple Music/Cassette comparison showed an overly neutral/bright Cassette field
and insufficient bottom depth. Scene metering now includes a continuously chroma-weighted
anchor (no fixed hue or album colors), post-blur saturation is 1.04–1.16 rather than 0.88–1.03,
and the exposure curve adapts to source luminance spread/chroma. Motion, texture cache, P3
conversion, blur count and render resolution remain unchanged. The reference is an app-switcher
screenshot at different playback positions; it cannot establish pixel-perfect matching.
Final verification of this correction: unsigned iOS build succeeded and 58 selected test
executions passed, including real cached/downloaded AAC AVPlayer seeks in playing and paused
states, local coalescing/settlement, lyric timing/scroll, interrupted background fades, and
neutral/color-anchor checks. Updated Xscape frames at 0/30/90 seconds were inspected.
Logs: `/tmp/cassette-local-seek-background-tests.log` and
`/tmp/cassette-local-seek-background-ios.log`. Physical iPhone scroll/frame-time profiling and
same-device full-screen Apple Music comparison remain unperformed.
