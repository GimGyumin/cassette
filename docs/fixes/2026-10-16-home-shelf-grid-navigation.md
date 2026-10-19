# Home shelf grid navigation

## Problem and change

The Home shelf heading opened `AlbumShelfCollectionView` with a view-destination
`NavigationLink`, while albums inside that grid pushed `HomeDestination` values
onto the root navigation path. Mixing those two presentations left the grid
outside the value path containing its album detail and could present the grid
over the newly selected album.

The shelf heading now pushes `HomeDestination.albumCollection`. Its immutable
`AlbumShelfCollection` stores the section title, album snapshot, and each album's
destination. The grid and album detail therefore belong to the same path:
Home → collection → album. Back navigation retains the collection entry.
Existing customizable album destinations and album context menus are preserved.

The destination is registered in MainTabView, standalone HomeView, SearchView,
and the macOS root so the shared shelf component resolves consistently. No
additional navigation stack, delayed presentation, or forced dismissal was added.

## Validation

- iOS Generic Device build, code signing disabled: **BUILD SUCCEEDED**.
  Log: `/tmp/cassette-shelf-navigation-ios.log`.
- macOS arm64 `HomeDiscoveryFeedTests` and `HomeDiscoveryPresentationTests`:
  **6 passed, 0 failed, 0 skipped**, no reported runtime warnings.
  Log: `/tmp/cassette-shelf-navigation-tests.log`.
  Result: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.16_11-16-44-+0900.xcresult`.
- No simulator was used. These tests validate existing Home content and component
  presentation; they do not exercise an iOS navigation push or interactive pop.
  Repeated section → album selections, back navigation, and interactive back
  gestures still require physical iPhone verification.
