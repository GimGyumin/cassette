# Immersive Now Playing reference — build 1027

Reference: the user's second screenshot (Apple Music), 1206 × 2622 pixels,
equivalent to a 402 × 874 point viewport. The first screenshot is Cassette.

Measured layout at that viewport:

| Element | New geometry |
| --- | --- |
| Sharp artwork | Full width, top at actual top safe inset + 8pt (70pt with a 62pt inset) |
| Grabber | 60 × 4pt, existing safe-area-relative top placement |
| Title/artist | 20pt SF Default; top around 496pt; leading inset 32pt |
| Seek bar | Leading/trailing inset 32pt; center around 575pt |
| Time/quality row | Compact 22pt chip; stable slot below the seek bar |
| Transport | Center around 666pt; skip glyph 28pt, play/pause 38pt |
| Volume | Center around 755pt; leading/trailing inset 32pt |
| Footer | Center around 808pt; existing live route name/icon |

The foreground and background now share one full-viewport coordinate space
derived from the presenting GeometryReader and both safe-area insets. Slots
compress upward on short phones, keeping controls separate. Accessibility text
sizes retain the established standard player layout.

Background corrections:

- Removed the full-cover aspect-fill blur extending the central portrait through
  the controls (and introducing unrelated warm colors on the silver sleeve).
- Extend only the original top/bottom 4% edge bands; keep the square sharp image
  at its source scale, below the status area, with a later lower-edge crossfade.
- Limit the lower band's exposure using the prepared edge RGB. The title/footer
  gradient is monotonic, and white/gray sleeves remain dark enough for light UI.
- Use fixed light-chrome ink for this profile rather than the palette's faint
  secondary text over a bright wash.
- Known images render directly; fallback cover loads still go through the shared
  cache. There is no new decoding/edge-analysis task in a view body.

Scope: iPhone portrait immersive player. Album navigation/zoom, the landscape
player, lyrics/queue layouts, playback/seek and native output/volume actions are
retained. Compact quality styling is opt-in for this profile.

Artwork limitation: the screenshots contain different printed content (the first
has a Michael Jackson/Thriller signature absent from the second). Layout/color
changes cannot reproduce different editorial artwork. No title-specific graphic
erasure, artist/album exception, or replacement asset was added.

Validation:

- Six macOS tests passed: measured layout rendering, five phone viewport sizes,
  white/gray edge-extension color/contrast, actual track-info fixture rendering,
  landscape quality label, and landscape column separation.
- Visually inspected the generated fixture (synthetic sleeve, production track
  info and transport/quality controls). Output: temporary
  cassette-1027-immersive-layout.png and cassette-1027-immersive-background.png.
- Final arm64 iOS Simulator build-for-testing passed without warnings/errors;
  git diff --check passed.
- No iOS simulator runtime is installed, so device-level safe-area, UIKit
  controls and screenshot parity still require an iPhone check.
