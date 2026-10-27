# Cassette Design System

A lightweight, token-based design system for SwiftUI. The goal is visual consistency across all screens with no magic numbers in view code.

---

## Colors

Defined in two places:

| Source | What lives there |
|--------|-----------------|
| `Assets.xcassets` | `CassetteAccent`, `CassetteAccentSecondary` — Xcode auto-generates `Color.cassetteAccent` etc. with light/dark variants |
| `CassetteColors.swift` | `cassetteAccentText`, `cassetteCoverShadow`, `cassetteCoverBorder` — pure Swift constants |

See `CassetteColors.md` for the full palette table, WCAG contrast notes, and usage rules.

**Critical rules:**
- `cassetteAccent` is for **primary interactive elements only** (play button, scrubber, active toggles, tappable artist name). Never on body copy or captions.
- All text and backgrounds use SwiftUI semantic colors (`Color.primary`, `.secondary`, `Color(.systemBackground)`, etc.).
- Never add custom colors without updating `CassetteColors.md`.

---

## Spacing

Use `CassetteSpacing` constants everywhere. Never write a literal `CGFloat` for spacing.

```swift
enum CassetteSpacing {
    static let xs:    CGFloat = 4
    static let s:     CGFloat = 8
    static let m:     CGFloat = 12
    static let l:     CGFloat = 16   // standard padding
    static let xl:    CGFloat = 20
    static let xxl:   CGFloat = 24
    static let xxxl:  CGFloat = 32
    static let xxxxl: CGFloat = 48
}
```

---

## Corner Radii

```swift
enum CassetteCornerRadius {
    static let xs:       CGFloat = 4
    static let s:        CGFloat = 6
    static let standard: CGFloat = 8   // list thumbnails, buttons
    static let large:    CGFloat = 12  // cover art in detail views, mini-player card
    static let pill:     CGFloat = 999 // capsule buttons
}
```

---

## Typography

All font styles are `Font` extensions defined in `CassetteTypography.swift`. Use them instead of `.font(.title2)` + `.fontWeight(.semibold)` pairs.

| Token | Spec | Usage |
|-------|------|-------|
| `.cassettePlayerTitle` | `.title`, rounded, bold | Track title in FullPlayerView |
| `.cassetteDetailTitle` | `.title2`, rounded, semibold | Album/playlist name in detail header |
| `.cassetteSectionTitle` | `.headline`, rounded, semibold | Section headers in scroll views |
| `.cassetteBody` | `.body` | Body copy |
| `.cassetteCellTitle` | `.callout`, medium | Primary text in list cells |
| `.cassetteCellSubtitle` | `.subheadline` | Secondary text in list cells (artist name, owner) |
| `.cassetteCaption` | `.caption` | Metadata (year, track count, duration) |
| `.cassetteCaption2` | `.caption2` | Smallest text (footnotes, timestamps) |

---

## Cover Art

### `CoverArtCard`

The standard wrapper for any cover art thumbnail. Handles async loading, 1:1 clip, and adaptive shadow (light) / border (dark).

```swift
// Standard list thumbnail
CoverArtCard(id: album.coverArt ?? album.id, size: 56)

// Large detail header (album, playlist)
CoverArtCard(id: album.coverArt ?? album.id, size: 220, cornerRadius: CassetteCornerRadius.large)

// Mini-player
CoverArtCard(id: track.coverArt ?? track.id, size: 44)
```

**Do not** use `CoverArtView` directly in views and manually apply `.clipShape` + `.shadow`. Always prefer `CoverArtCard`.

**Exception**: flexible-width contexts (2-column grids) where the size is determined by geometry. Use `CoverArtView` + `.cassetteCoverStyle(cornerRadius:)` + `GeometryReader` in that case.

### `.cassetteCoverStyle(cornerRadius:)`

The view modifier that `CoverArtCard` applies internally. It clips the view and adds:
- A drop shadow in light mode
- A 1pt white-8% border in dark mode (shadows are invisible against dark backgrounds)

---

## Components

### Settings forms

`SettingsSubpageStyle` uses native inset-grouped forms on iOS: semantic grouped
backgrounds, inline navigation titles, green switches, and blue links/checkmarks.
Use `SettingsSectionHeader`, `SettingsSectionFooter`, `SettingsNavigationRow`, and
`SettingsChoiceList` to keep descriptions outside the rounded cards. Rows use
`CassetteSettingsLayout` and Dynamic Type fonts; do not give them fixed heights.

### Album navigation

`AlbumNavigationLink(album:namespace:) { namespace in … }` pushes the standard
`HomeDestination.album` route on iOS (and the normal detail route on macOS). Album
pages use the default NavigationStack transition. Do **not** add a navigation zoom
transition to the album page: the interactive pop is owned by UIKit's normal
transition, and a matched source inside a lazy/re-created shelf can invalidate it.
Cover expansion inside the page may use `.cassetteZoomTransition` separately.

### Seamless album artwork

`ArtworkEdgeAnalyzer` samples a 64×64 sRGB raster on an artwork preparation task.
`ArtworkEdgeAnalysis` stores only image facts, its algorithm version, and a pixel
fingerprint. The persisted `ArtworkPalette` includes those facts while remaining
compatible with older cache records. `AlbumCoverPreloadService` performs this work
during library preparation, including a disk-only pass for already cached artwork.
Ordinary image loads and album-page tasks never start edge analysis.
`ArtworkImageCache` scopes results/preferences to the account and invalidates facts
on cover replacement.

Compact album pages use `SeamlessArtworkHero` only for a confident opaque uniform
border (or the album's explicit Full-Width preference). It fits the entire image
into a full-width square; no fade or crop removes artwork near the bottom.
The existing dominant-color palette and manual override still determine the page
background. `AlbumAtmosphere` chooses contrast from that canvas, independently of
the layout decision. Edge-analysis version 2 backfills the earlier preparation policy.
Other covers keep `ImmersiveCoverHero`'s inset card. The root navigation stack and
mini player remain responsible for transitions and playback chrome.

### `SongRow`

Standard track cell for album and playlist detail screens.

```swift
// Album context — shows track number
SongRow(song: song, index: index + 1)

// Playlist / search context — shows thumbnail
SongRow(song: song, index: index + 1, showCoverArt: true)

// With download badge
SongRow(song: song, index: index + 1, isDownloaded: true)

// Currently playing (accent title)
SongRow(song: song, index: index + 1, isCurrentTrack: true)
```

### `AlbumRow`

Flat list cell — 56pt thumbnail, name, artist, year.

```swift
AlbumRow(
    albumId: album.id,
    name: album.name,
    artist: album.artist,
    year: album.year,
    coverArtId: album.coverArt
)
```

Use in flat lists (search results, etc.). For grids, use `CoverArtView + cassetteCoverStyle` directly.

### `ArtistRow`

List cell with an initials avatar (gradient circle). Does not attempt to load a cover art image — Subsonic servers rarely supply artist artwork.

```swift
ArtistRow(artist: artist)
```

### `PlayButton`

The primary "Play" action button — orange capsule, white label, `play.fill` icon.

```swift
PlayButton(action: {
    Task { try? await playerService.play(tracks: songs, startIndex: 0) }
}, isDisabled: songs.isEmpty)
```

Pairs with an icon-only download/cancel button in the same `HStack`.

### `EmptyStateView`

Used for error states, empty libraries, and empty search. Replace all `ContentUnavailableView` usages with this.

```swift
// Error state with retry
EmptyStateView(
    systemImage: "exclamationmark.triangle",
    title: "Unable to Load Album",
    subtitle: error.localizedDescription,
    action: .init(label: "Retry") { Task { await vm.load() } }
)

// Empty state, no action
EmptyStateView(
    systemImage: "music.mic",
    title: "No Artists",
    subtitle: "Your library appears to be empty."
)
```

### `SectionHeader`

SF Pro Rounded semibold header for use inside scroll views (not inside `List`/`Section` headers).

```swift
SectionHeader("Recent Albums")
```

---

## Adding a new component

1. Create `DesignSystem/Components/MyComponent.swift` with the MPL-2.0 header.
2. Use only design system tokens (no magic numbers, no hardcoded colors).
3. Add a `#Preview` block.
4. Document it in this file under **Components**.

## Adding a new color

1. Add the color set to `Assets.xcassets` with both Any and Dark Appearance variants.
2. Add a row to the palette table in `CassetteColors.md` with WCAG notes and permitted uses.
3. Do **not** add a manual `Color` extension — Xcode generates `Color.<assetName>` automatically.

### Album artwork presentation (1008)

Prepared `ArtworkEdgeAnalysis` v3 selects Uniform, Faded or Standard. Uniform
uses `SeamlessArtworkHero` with exact edge color and no fade. Texture/gradients
use `FadedArtworkHero`: full-width square, noninteractive lower gradient and a
single layout-sized title over a separate dark content canvas. Complex edges
keep `ImmersiveCoverHero` inset presentation. Both full-width components request
the 1200 px hero tier; no pixel analysis occurs in view rendering or scrolling.
See [the implementation and validation report](../../docs/fixes/2026-10-21-album-artwork-presentation-v3.md).
