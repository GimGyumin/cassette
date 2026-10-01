# Contributing to Cassette

## Development Rules

### B2 — No SwiftSonic bypass, ever

All Subsonic API calls MUST go through `SwiftSonic`. No `URLSession` calls to server
endpoints directly from Cassette code.

If a SwiftSonic API is missing or awkward:
1. Note it in `APP_FEEDBACK.md` (never committed — see `.gitignore`)
2. Work around it using existing SwiftSonic methods, even if inelegant
3. Keep building — SwiftSonic 0.6.x will address the friction points

**Single exception**: a critical security bug in SwiftSonic → hotfix SwiftSonic
immediately (e.g. a 0.4.1-style patch), do not bypass.

**Alarm signal**: if you are writing more than 10 lines of networking code in Cassette
that do not go through SwiftSonic, stop and discuss.

### B3 — v1 simplifications (documented)

Three deliberate simplifications for v1. Each is marked with
`// TODO(v1.x): <planned evolution>` in the code so they are easy to find later.

| Feature | v1 | v1.x |
|---|---|---|
| Audio cache during stream | Full background download alongside stream | `AVAssetResourceLoaderDelegate` chunk interception |
| Permanent downloads | Foreground `URLSession` (user keeps app open) | Background `URLSession` with resume after app kill |
| Server queue sync | Best-effort `savePlayQueue`/`getPlayQueue`, silently ignored on failure | Robust bidirectional sync with multi-device merge |

### SwiftData + Actor pattern

`ModelContext` is main-thread-bound. Actor methods that read or write SwiftData
must always create and use a `ModelContext` on the MainActor:

```swift
try await MainActor.run {
    let context = ModelContext(modelContainer)
    // fetch, insert, delete, save here
}
```

`@Model` objects (e.g. `ServerConfig`) **never** leave the `MainActor.run` closure.
Return a `Sendable` DTO (`ServerSnapshot`, etc.) instead. This is the single rule
that makes the entire service layer actor-safe with SwiftData.

Tests must pass `inMemory: true` to `ModelContainer.cassette(inMemory:)` — Swift
Testing parallelises tests, so each test must own its own in-memory store.

### Architecture invariants

1. Files under `Services/` never `import SwiftUI`, `UIKit`, or `AppKit`.
2. `PlayerService` is the **single source of truth** for playback state.
   No duplicated playback state in any view model.
3. `MediaResolver` is the **single entry point** for playable URLs.
   `PlayerService` always asks `MediaResolver` — never SwiftSonic directly.
4. All dependencies injected via `init`. No singletons except `AppContainer`.
5. `NowPlayingService` is active from v1 (lockscreen / Control Center / AirPods).
6. Nothing reads `ProcessInfo` / `UIAccessibility` to decide how expensive it may be —
   CPU/GPU-heavy work is throttled through `PerformanceBudget` /
   `PerformanceGovernor` (`CassettePerformance` is the non-isolated façade, including
   for the audio render thread). See `docs/ARCHITECTURE.md` → *Battery, thermal and
   performance budget*, and prefer degrading to a cached/cheap value over dropping a
   feature (and never add a `TEMP` kill switch).

### nonisolated on static properties in system type extensions

When `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is active (our project build
setting), every `static let` or `static var` inside an `extension` on **any**
type — including system types like `Logger`, `DateFormatter`, or `JSONDecoder` —
is implicitly `@MainActor`. Reading those properties from a non-MainActor context
(an `actor`, a detached task, a `nonisolated` function) produces a Swift 6
concurrency warning today and will be a compiler error in strict mode.

**Rule**: any `static let/var` in an extension on a system type that is accessed
outside the main actor must be annotated `nonisolated`:

```swift
// ✗ implicitly @MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor
extension Logger {
    static let keychain = Logger(subsystem: "...", category: "...")
}

// ✓ safe across all isolation boundaries
extension Logger {
    nonisolated static let keychain = Logger(subsystem: "...", category: "...")
}
```

This is safe whenever the type is `Sendable` and holds no mutable state.
`Logger` (OSLog), `DateFormatter` created once, immutable `JSONDecoder`, and
similar value-type constants all qualify. When in doubt, add `nonisolated` —
the compiler will tell you if it cannot be applied.

### Design system

All UI code must use the design system. Never write magic-number spacing, hardcoded colors, or one-off font modifiers in view files.

| Resource | Rule |
|----------|------|
| Spacing | Use `CassetteSpacing.*` (`l` = 16, `xxl` = 24, etc.) — never a raw `CGFloat` literal |
| Corner radii | Use `CassetteCornerRadius.*` — never `RoundedRectangle(cornerRadius: 8)` with a bare number |
| Typography | Use `Font` extensions from `CassetteTypography.swift` (`.cassetteCellTitle`, `.cassetteCaption`, etc.) |
| Cover art | Use `CoverArtCard` — never `CoverArtView + .clipShape + .shadow` inline |
| Colors | Semantic SwiftUI colors for text/background; `cassetteAccent` only on primary interactive elements |
| Empty/error states | Use `EmptyStateView` — never `ContentUnavailableView` |

See `Cassette/DesignSystem/README.md` for the full component catalogue, token reference, and rules for adding new components or colors.

### Keychain policy

Credentials (passwords, `customHeaders`) are **never** in:
- `UserDefaults`
- Log statements (even at debug level)
- Error messages shown to users

Keychain only. `ServerCredentials` carries an `// IMPORTANT: Never persist outside of Keychain` comment to reinforce this.

### Commit style

Conventional commits: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
One atomic commit per subtask. Propose a plan and wait for validation before
implementing each numbered Étape.

---

## Quality gates

Before pushing to `origin/main`, the build must be **warning-free** (excluding
the known acceptable warnings listed below).

Run the following commands and inspect the filtered output — it must be empty:

```sh
# iOS (required)
xcodebuild -scheme Cassette \
  -destination 'generic/platform=iOS Simulator' \
  clean build 2>&1 \
  | grep -E "warning:|error:" \
  | grep -v "/SourcePackages/" \
  | grep -v "appintentsmetadataprocessor"

# macOS (required) — the target ships alongside iOS, so it is gated on every PR.
# CODE_SIGNING_ALLOWED=NO keeps the gate runnable on machines without the
# Developer ID certificate; signing is not part of the quality gate.
xcodebuild -scheme Cassette \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 \
  | grep -E "warning:|error:" \
  | grep -v "/SourcePackages/" \
  | grep -v "appintentsmetadataprocessor" \
  | grep -v "AppIcon.appiconset" \
  | grep -v "ConformanceIsolation"

# Test target (required) — the app-only gate let the test target rot unseen.
# A macOS destination needs no simulator runtime, and runs the suite instead of
# only compiling it (same shape as CI and the release workflow).
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Any new warning must be fixed or explicitly added to the "Known acceptable
warnings" section with full justification before merging.

---

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request:

| Job | What it enforces |
|-----|------------------|
| **iOS build (warning gate)** | Clean iOS Simulator build; fails on any warning or error that is not a documented exception. |
| **macOS build (warning gate)** | Clean unsigned macOS build; same gate, so the second target can no longer rot silently. |
| **Unit tests** | `CassetteTests` on a macOS destination — simulator-runtime independent, matching the release workflow. |

The gates apply the same filters as the commands above plus the patterns listed
under "Known acceptable warnings". Adding a filter without an entry there is a
silent regression: the entry is what makes the exception reviewable and dated.

Run the same gates locally before pushing:

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

---

## Known acceptable warnings

These warnings appear during normal builds and are **intentionally not fixed**.
Each entry records source, cause, action taken, and when to revisit.

---

### MediaSessionRepresentable conformance isolation

```
warning: conformance of 'CassetteMediaSessionRepresentation' to protocol 'MediaSessionRepresentable'
crosses into main actor-isolated code and can cause data races; this is an error in the Swift 6
language mode [#ConformanceIsolation]
```

| Field    | Details |
|----------|---------|
| **Source** | `Cassette/Services/Playback/CassetteMediaSessionController.swift` — `CassetteMediaSessionRepresentation` |
| **Cause** | The iOS 27 `NowPlaying` framework declares `MediaSessionRepresentable` without an isolation annotation, while Cassette's representation is `@MainActor` (it is mutated from the player and the UI). The isolation mismatch is theoretical: both sides live in the app process. |
| **Action** | Fixed-by-exception. `@preconcurrency` on the conformance was measured and has no effect here, and there is no safe way to move `content` / `playbackSnapshot` off the main actor. Suppressed by the `ConformanceIsolation` filter in the quality-gate and CI commands; the doc comment at the declaration points here. |
| **Revisit** | When the app target moves to the Swift 6 language mode, or when `MediaSessionRepresentable` documents its isolation contract. |

---


```
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
```

| Field    | Details |
|----------|---------|
| **Source** | Xcode build system — `appintentsmetadataprocessor` runs on every project |
| **Cause** | The processor is injected by Xcode regardless of whether the project uses AppIntents. It emits this warning when `AppIntents.framework` is absent from the dependency graph. |
| **Action** | Suppressed by the `-v "appintentsmetadataprocessor"` filter in the quality-gate commands above. Cassette now ships App Intents (`Cassette/Siri`), so the app target no longer emits this line; the filter is kept as a safety net for targets without the dependency. |
| **Revisit** | When every target in the project links AppIntents — then the filter (and this entry) can be deleted. |

---

### App icon PNG size mismatch

```
warning: AppIcon.appiconset/cassette-wow-loop-1024 N.png is 1024x1024 but should be <size>.
```

| Field    | Details |
|----------|---------|
| **Source** | `Assets.xcassets/AppIcon.appiconset` — 10 PNG slots for macOS sizes 16×16 through 512×512 |
| **Cause** | All macOS app icon slots are currently filled with the 1024×1024 master PNG. Xcode compiles them but emits a size-mismatch warning for each slot that expects a smaller size. iOS is unaffected (uses a single 1024×1024 slot). |
| **Action** | Pre-existing warning — no code fix possible. Proper resolution requires exporting correctly-sized PNG variants (16, 32, 64, 128, 256, 512 pt, 1× and 2×) from the original icon source and replacing the placeholder assets. |
| **Revisit** | Before App Store submission for the macOS target — regenerate the full icon set from the final design source. |

---

## Licensing

By contributing code to this repository, you agree that your contributions will be licensed under the Mozilla Public License 2.0, the same license that covers the project.

All new Swift files must include the MPL-2.0 header at the top of the file:

```swift
// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.
```

Dependencies added to the project must use MPL-2.0-compatible licenses (MIT, Apache 2.0, BSD, LGPL, or MPL itself). Non-compatible licenses (proprietary, CC-BY-NC) must be discussed and approved before inclusion.
