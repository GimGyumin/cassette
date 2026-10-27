# Build 1005 — Music settings and album navigation

## Settings

The in-app settings now follow the supplied Music settings references: an inline
Music title, native rounded inset groups, a semantic black background in dark mode,
green switches, blue actions/checkmarks, and secondary explanatory text below cards.
The root groups Library, Audio, Downloads, Lyrics, Sharing, Account, and App. Existing
account, storage, diagnostics, permissions, and playback controls remain reachable.

Dolby Atmos has its own selection page, retaining Cassette's existing on/off server
variant preference and metadata-preserving behavior. Audio Quality has a lossless
master switch plus Wi-Fi, cellular, and download subpages. Choices have full-width
hit areas, a trailing checkmark, and VoiceOver selected traits. Fonts scale with
Dynamic Type; row height is a minimum, not a fixed cap. New text has English and
Korean translations.

The reference's unsupported Apple-specific features are not presented as working
Cassette controls: there is no invented AutoMix, output-aware Atmos mode, iCloud
library synchronization, or fixed ALAC resolution conversion. Cassette keeps its
real Automatic / original lossless / AAC / Opus choices. High-resolution originals
are covered by the original-file option rather than a fictitious 192 kHz setting.

## Lossless preference behavior

- Enabled by default, so upgrading from 1004 retains existing playback behavior.
- Off maps Automatic and original-file quality preferences to AAC 256 for ordinary
  new server streams and downloads. Explicit AAC 128/Opus choices are retained.
- Saved network/download choices remain intact and return when re-enabled.
- The switch is persisted, reloadable, resettable, and available on macOS too.
- DownloadService uses the same effective-format mapping as StreamingSettings.
- Wi-Fi quality upgrades check the switch before preparation and again before
  committing. A change during preparation retains the already-playing stream.
- Already downloaded/cached files keep their encoding. Explicit original-file
  server routes and spatial bitstream preservation retain their existing semantics;
  the UI explains this exception. The switch does not restart current playback.

## Album navigation

`AlbumNavigationLink` stores a source-specific, immutable route in the same
NavigationPath as other detail pages. Each page/shelf owns a namespace and uses
the stable server album ID within it, preserving identity across lazy-cell recycling. Repeated appearances of an album on different
shelves therefore cannot compete for one transition source.

Native zoom is connected for the Library album grid/list, Library Recently Added,
shared Home/Discover album shelves, and their See All grids. Destination registration
lives on stable root content in each iOS stack, outside reachability-dependent views.
The destination continues to use the 1004 preloaded cover/theme and immediate header.
The mini player stays at the root. No extra scaling animation, timing curve, overlay,
or nested NavigationStack is added. macOS uses the existing detail route. Search
history, deep links, pinned/ID-only and artist-to-album links retain standard navigation.

The system controls animation and interactive return. Source corner configuration is
opt-in for album covers so the existing mini-player transition shape is preserved.

Official API references:
- [ZoomNavigationTransition](https://developer.apple.com/documentation/swiftui/zoomnavigationtransition)
- [matchedTransitionSource configuration](https://developer.apple.com/documentation/swiftui/view/matchedtransitionsource(id:in:configuration:))

## Validation

- iOS Simulator-target builds succeeded (both arm64 and x86_64); final validation is
  recorded in `/tmp/cassette-1005-verified-ios.log`.
- macOS app/test compilation and focused settings, format, network policy, resolver,
  Atmos matching, and HTTP seek/handoff regression suites passed: 107 executions, zero failures, in
  `/tmp/cassette-1005-final-tests.log`. The final UI-only refinements are also compiled
  for macOS in `/tmp/cassette-1005-verified-mac.log`.
- Added persistence/restore, effective format, reset, real resolver AAC request,
  master-off handoff rejection, and settings-change-during-preparation checks.
- This Mac has no available iOS Simulator runtime. No iPhone screenshot or interactive
  gesture run is claimed. On-device verification remains: light/dark settings, larger
  text, VoiceOver, selecting quality then relaunching, rapid open/back and cancelled
  interactive album returns, See All → album → artist → back, and playback with a
  visible mini player throughout those transitions.
