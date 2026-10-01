# Cassette architecture

Playback request ownership, buffering, and recovery were revised on 2026-09-28.
See [Playback redesign](PLAYBACK_REDESIGN.md) for the current policy and validation
status; it supersedes older warmup/probe and handover descriptions below.

Cassette is a native SwiftUI client for Subsonic / OpenSubsonic servers, shipping an
iOS app, a macOS app, a widget extension and App Intents from one project. This
document is the map: which layer owns what, how a tap becomes audio, and where the
known debt lives. It is kept in sync with the code — update it in the same commit
as any structural change.

Figures below are from the 2026-09 audit: 466 Swift files / ~80k lines in
`Cassette/`, 76 unit-test files with 687 `@Test` cases.

---

## Layers

| Layer | Path | Owns |
|-------|------|------|
| **App** | `Cassette/App` | `AppContainer` (composition root), `CassetteApp`, commands, notifications, logout |
| **Views** | `Cassette/Views` | SwiftUI only: `Browse`, `Main` (player, home, search), `Settings`, `Onboarding`, `Platform` (iOS/macOS specific), `Wrapped`, lyrics views |
| **ViewModels** | `Cassette/ViewModels` | 21 `@Observable` view models; screen state, paging, formatting — no networking |
| **Observable state** | `Cassette/ObservableState` | Long-lived shared state: `PlayerState`, `ServerState`, `CacheSettings`, `StreamingSettings`, `AppleMusicSettings`, `CrossfadeSettings`, `ReplayGainSettings` |
| **Services** | `Cassette/Services` | `Protocols/` (13 service protocols) + `Implementations/` + domain folders (`Playback`, `Cache`, `Lyrics`, `Networking`, `Integrations`, `Recommendations`, `Intelligence`, …) |
| **Models** | `Cassette/Models` | `Domain` (value types), `Persistence` (SwiftData), `Integrations`, `Navigation`, `Wrapped`, `Recommendations` |
| **Design system** | `Cassette/DesignSystem` | Tokens (color/spacing/type/animation) and shared components — see its `README.md` |
| **Utilities** | `Cassette/Utilities` | Formatting, language/locale, logging, caches, platform shims |

Views never reach a service directly: `AppContainer` is injected through the
SwiftUI environment and view models are constructed from it.

## Dependency injection

`AppContainer` (`Cassette/App/AppContainer.swift`) is the only place that knows
concrete implementations. It wires:

- shared `@Observable` state (`PlayerState`, `ServerState`, settings objects);
- SwiftData `ModelContainer`s (library data + listening history);
- the 13 service protocols (`ServerServiceProtocol`, `LibraryServiceProtocol`,
  `CacheServiceProtocol`, `DownloadServiceProtocol`, `MediaResolverProtocol`,
  `PlayerServiceProtocol`, `NowPlayingServiceProtocol`, `FavoritesServiceProtocol`,
  `PinServiceProtocol`, `PlaylistServiceProtocol`, `RadioServiceProtocol`,
  `KeychainServiceProtocol`, `SiriCatalogServiceProtocol`).

Tests construct the same object graph with fakes, which is why every service is
consumed as `any XxxServiceProtocol`.

## Playback pipeline

1. A view calls a view model, which calls `PlayerServiceProtocol` (an **actor**, so
   audio state has a single owner).
2. `MediaResolver` + `AudioQualityClassifier` decide *how* the track is fetched:
   lossless original bitstreams stay untouched, surround and Dolby sources are
   handed to a system player, everything else may go through cache/transcode.
3. `CacheService` / `DownloadService` provide a local file when one exists or when
   the cache policy (per Wi-Fi / cellular / downloads) asks for one.
4. The engine (`// MARK: - Playback engine` in `PlayerService`) runs dual-path:
   `AudioStreaming` (AVAudioEngine) for stereo and `AVPlayer` for spatial /
   multichannel / wireless routes, with gapless pre-queue and crossfade handled by
   their own sections.
5. Progress, scrobbles, stats and widget/Now Playing metadata are pushed by timers
   and helpers observing the same actor state (`NowPlayingService`,
   `WidgetSyncService`, `StatsService`, ListenBrainz).

Audio quality labels (`AudioQualityKind` in
`Cassette/Models/Domain/AudioQualityInfo.swift`) are derived from server metadata
and shown on albums, in the player and in the song info sheet: `dolbyAtmos`,
`dolby(codec:channels:)`, `multichannel(channels:codec:)`, `hiResLossless`,
`lossless`. Dolby and multichannel badges stay visible even when the request
reports transcoding — those streams are bitstreamed raw.

### Gapless playback

Consecutive queue transitions are seamless by default: at track start
`PlayerService` resolves the *next* entry and hands it to the AudioStreaming
engine (`audioPlayer.queue`), which pre-buffers it. When EOF arrives the engine has
already moved into that entry, so `finalizeGaplessBridge` advances app state
(current track/index, Now Playing, scrobble, ReplayGain) **in place** instead of
calling `play()`, which would flush the engine and re-create the silence.

Whether an entry may be armed is decided by `GaplessPolicy` (pure, unit-tested in
`GaplessPolicyTests`), not by ad-hoc checks in the queue code:

| Condition | Result |
|---|---|
| Nothing follows the track | no bridge (`.endOfQueue`) |
| Crossfade > 0 and the pair is not a gapless album pair | no bridge (`.crossfade`) |
| Crossfade > 0, album pair, "Disable for gapless albums" on | bridge (`.bridge`) |
| Next track is multichannel / Atmos (AVPlayer path) | no bridge (`.requiresSystemPlayer`) |
| Gapless turned off in Settings → Playback | no bridge (`.disabledByUser`) |
| Metered **or constrained** network (Low Data Mode), remote stream, cellular use off | no bridge (`.meteredNetwork`) |
| Device thermally critical / memory pressured / backgrounded | no bridge (`.deviceConstrained`) |
| Anything else (playlist, shuffle, Autoplay) | bridge (`.bridge`) |

Every non-bridge outcome is logged with its reason
(`[GAPLESS] '<title>' not pre-queued — <reason>`), so a reported "gap" can be
diagnosed from a device log instead of guesswork. The stale-bridge guards stay: if
the queue changed after arming, or the watchdog fired without the engine confirming
EOF, the bridge is flushed and the normal `play()` path takes over.

**Watchdog vs. bridge.** The end-of-track watchdog runs off *metadata* duration,
which is often a touch shorter than the real stream, so it can fire while the engine
is still switching into the pre-buffered entry. Tearing the bridge down there made
the next track play for ~1 s and then restart from zero (the engine had advanced, and
`play()` re-loaded it). `handleEndOfTrack` therefore gives an armed bridge a grace
window: `audioPlayerDidStartPlaying` (authoritative) or the engine's clock restarting
near 0 confirms the transition, and app state is advanced in place. Only when neither
appears within the window is the bridge cancelled and the normal advance used.

Gapless is **not** limited to album siblings any more — playlists, shuffled
queues and Autoplay transitions are seamless too. Low Power Mode deliberately keeps
it enabled (it is a listening behaviour, not decoration); only a thermally
critical device, memory pressure or the app being backgrounded defers the
pre-buffer (see the budget table below).

### Lyrics: server + external race

Every lyrics surface (full player, mini player, library generator) asks `LyricsService`,
an actor. Embedded (server) lyrics used to be fetched *and then* the LRCLIB fallback, so a
slow server made the screen wait for both in series — the 8.3 s cold open in the log. Both
lookups now start together inside `resolveEmbeddedWithFallback` (`withTaskGroup`) and one
pure function decides the winner:

```swift
LyricsService.chooseSource(embedded:embeddedSettled:external:externalSettled:serverHeadStartElapsed:)
```

- The server gets a **1.5 s head start**: a usable external answer that lands first waits
  that long, so karaoke coming from the server is never pre-empted by plain LRC.
- Server karaoke always wins; external karaoke upgrades plain server lyrics; external
  *synced* lyrics upgrade unsynced server lyrics; an empty or failed server answer defers to
  any usable external one.
- A losing lookup is discarded when the decision is made; the task group is cancelled on
  return, so nothing keeps running for a surface that already moved on.
- The decision is pure, so every branch is unit-tested without a network
  (`CassetteTests/LyricsSourceRaceTests.swift`).

## Network cost

`NWPath.isExpensive` only flags metered links (cellular, hotspot). A throttled Wi-Fi link, or one
iOS reports as constrained (Low Data Mode), limits the same background work without being
"expensive" — which used to let the app run the live stream, the ephemeral cache, the gapless
pre-buffer and the crossfade prefetch against one slow link at once.

`NetworkMonitor` records both `isExpensive` and `isNetworkConstrained`, and
`ServerState.isLimitedNetwork` folds them through the pure `NetworkCostPolicy`. Everything that
spends bandwidth in the background — ephemeral cache writes, gapless pre-buffering, crossfade
prefetch, automatic downloads, speculative next-track artwork, and the stream-quality choice in
`MediaResolver` — gates on `isLimitedNetwork`, never on `isExpensive` alone. On a limited network
those transfers stay opt-in behind the user's cellular switches (Settings → Cache and
Settings → Audio Quality → Downloads, which are independent: turning downloads off does not stop
the streaming cache).

### Adaptive "Automatic" on a limited network

`NetworkSpeedProbe` samples the link once per server (a bounded ranged read of the SwiftSonic
stream URL — 96 KB / 1.5 s max, reused for 10 minutes) and `AdaptiveQualityPolicy` turns the rate
into a ceiling, keeping 2× headroom over the codec bitrate. It only ever *lowers* quality and only
when the user left the choice on **Automatic** (`CacheFormat.matchStream`) or the server playback
method on **Automatic**: an explicit quality (Lossless, AAC, Data Saver) or route (Direct Play,
Universal, HLS, …) is an instruction and is never overridden. Dolby/multichannel still bypasses
transcoding entirely.

## Jellyfin playback methods (always Automatic)

`JellyfinPlaybackRoute` names the routes a resolve can take, but it is **not** a setting: Settings →
Audio Quality has no playback-method row, and `MediaResolver` always asks `PlaybackDecisionPolicy`
for `.automatic`. Direct Play vs a server-side transcode therefore follows from the configured
quality, the current network and the source itself. Passing a concrete route still returns it
unchanged, so a future manual override would not need any policy change.

Jellyfin's own model is that the client posts what it can decode and what the connection allows, and
the server answers Direct Play or Transcoding. The app used to send an **empty** `PlaybackInfo` body,
so Navidrome answered "Direct Play is fine" for a lossless original even on a 1 Mbps link.
`JellyfinPlaybackInfoRequest` now carries `MaxStreamingBitrate` (bit/s) plus a `DeviceProfile`
(`iOSAudioCapability.deviceProfile`) with the containers/codecs this app can decode.

Navidrome's Jellyfin layer is experimental and may ignore parts of that, so the client keeps the
final say. `PlaybackDecisionPolicy` combines three inputs and never returns `.automatic`:

| Input | Source |
|---|---|
| `SupportsDirectPlay` / `SupportsDirectStream` / `SupportsTranscoding`, `Bitrate`, `Container`, `MediaStreams` | the `MediaSource` from `PlaybackInfo` |
| can this app decode that container/codec/sample-rate/bit-depth? | `iOSAudioCapability` |
| what may this connection use? | `AdaptiveQualityPolicy.streamingCeilingKbps` (user quality ∩ measured link) |

Order: an explicitly requested route (never set by the app today) → Dolby/Atmos/multichannel keeps the
bitstream (Direct Play) → downloaded file
(Direct Play) → Direct Play when it is decodable **and** fits the ceiling → Universal when it does not
and the server can transcode → OpenSubsonic when Jellyfin cannot (the Subsonic endpoint still applies
`maxBitRate`/`format`, which is exactly what a ceiling needs).

A source bitrate the server never reported is judged by container: a **lossless** container
(ALAC/FLAC/WAV/DSD…) is not assumed to fit a tight ceiling — that is the "ALAC 900 kbps under a
256 kbps cap" case — while a lossy one is, so a fast 5G link keeps Direct Play. Every decision is
logged once as `[ROUTE] '<id>' → <route> (reason=…, ceiling=…bps, limited=…)`.

Universal Transcoding requests are sent with `static=false`; `static=true` means "serve the file
untouched", which silently defeated the transcode the user asked for.

The probe runs whenever Automatic is in play, on **every** network — not just metered ones — because
iOS reports a throttled 1 Mbps Wi-Fi as unlimited, and that is the case that stalls. Its result is
published to `ServerState.measuredBytesPerSecond`, which feeds back into `NetworkCostPolicy`: a link
measured below `slowBytesPerSecond` (~2 Mbps) counts as **limited**, so a slow Wi-Fi link stops
background caching, prefetch, pre-buffering and cover preloading exactly like cellular does. A
later fast measurement clears it again.

When the engine still re-buffers mid-track (`playing → bufferring`), `PlayerService` counts the
underruns: one is a hiccup, two in one track mean the Automatic pick was too high. It then lowers
`StreamingSettings.adaptiveCeiling` one tier (`.matchStream → .aac256 → .aac128`, never past the
floor) and marks the link slow, so the next resolve is lighter and background work stops. The
ceiling is session-only and is cleared by a fast measurement, never persisted.

Choosing an explicit cellular quality in Settings skips the probe altogether, which is the way to
avoid the ~96 KB it costs.

`AlbumCoverPreloadService` — which otherwise downloads every album's hero cover — parks its pass
while audio is playing on a limited/slow link and resumes when playback stops (bounded at 5
minutes so preparation can still finish).

## LAN discovery

`JellyfinLANDiscoveryService` speaks the official Jellyfin UDP 7359 protocol ("Who is
JellyfinServer?"). iOS refuses a send to `255.255.255.255` unless the app holds Apple's **Multicast
Networking entitlement**, and that refusal used to be reported as "discovery is unavailable" even
after the user granted Local Network access. Discovery now sends the question to the **unicast**
address of every host on each usable IPv4 interface (`probeTargets()` → `hostAddresses(ipv4:netmask:)`,
bounded to `maximumHostScan` per interface) and keeps the broadcast as a best-effort extra: one
accepted datagram is enough to continue listening, so a refused broadcast no longer fails the round.
Only a blanket refusal (`EPERM` / `EACCES` / `ENETUNREACH`) becomes
`JellyfinLANDiscoveryError.permissionDenied`, which the sign-in screen shows with an Open Settings
button instead of a generic error.

`NSLocalNetworkUsageDescription` is required and present; the multicast entitlement is **not**
required by this design.

## Artwork priority and launch preparation

**Downloaded cover first.** A downloaded album stores its cover on disk under the id recorded
during library preparation, which is not always the song's own media-file cover id. Every playback
surface resolves through one rule (`AppContainer.playbackCoverId(for:)` — explicit cover id, then
the prepared album cover, then the song id) so the player, mini player and lock screen show the
**downloaded** artwork instead of opening a server request for a different image.
`NowPlayingSnapshot` carries `albumId` and `NowPlayingService` receives a prepared-id provider, so
the lock screen tries the downloaded id before the song's own one. `ArtworkImageCache` keeps its own
order — RAM → tiered disk → plain disk → network — so a downloaded file always wins over a fetch.

**Launch preparation.** `LibraryChangeDetector` compares the media-file count reported by
`getScanStatus` with the count recorded the last time the library was prepared, per server. A
different count means tracks were added or removed, and `LibraryPreparationService` then runs a
visible pass — rebuild the local index, reconcile album artwork (including covers whose id moved),
drop catalog-derived caches — behind `LibraryPreparationView`, which `RootView` overlays while the
phase is busy. Two rules keep it from being annoying: an unknown server count (never scanned) never
triggers work, and the **first** observation for a server only records the count, because the
onboarding pass already prepared that library.

### AVPlayer hand-over (why a track change is audible sooner)

The AVPlayer/Spatial path used to stop the outgoing item *first* and then start the incoming one, so the
listener heard silence for however long the server needed to warm up a transcode plus AVPlayer needed to
fill its buffer. Two things changed:

- **The outgoing player stays audible until the incoming one reports `.playing`.** `startEnginePlayback`
  parks it (`outgoingSystemPlayer`) instead of tearing it down, and `handleSystemPlayerTimeControlStatus`
  releases it the moment the new item produces audio. A parked player is also released by
  `pauseEngine`/`tearDownSystemPlayer` (pause/stop must never leave the previous track audible) and by a
  4 s `scheduleOutgoingSystemPlayerFailsafe`, so a stream that never starts cannot leave two tracks
  playing. Its observers are dropped when it is parked, so its end-of-track notification cannot skip the
  queue.
- **`preferredForwardBufferDuration` is 6 s, not 20 s** for remote streams: 20 s of a ~400 kbps
  transcode is ~1 MB, i.e. seconds of buffering before the first frame on a ~200 KB/s link.
  `automaticallyWaitsToMinimizeStalling` and the underrun adaptation remain the safety net.

`[TRANSITION-TIMING]` therefore logs three points: `resolve finished` (network + route decision),
`hand-over completed` (engine handed the URL) and `audio started … after the request` (what the listener
actually waits for).

## Stream quality: who decides

`Automatic` quality has two independent levers, and keeping them apart is what stops a healthy Wi-Fi
link from playing a lossy transcoded stream:

| Lever | Decided by | Effect |
|---|---|---|
| Cellular vs Wi-Fi **quality policy** | `isExpensive`/`isNetworkConstrained` only (metered, hotspot, Low Data Mode) | picks `cellularFormat` (default AAC 128) vs `wifiFormat` (Automatic) |
| **Adaptive ceiling** for Automatic | the measured throughput (`NetworkSpeedProbe` → `AdaptiveQualityPolicy`) | caps the stream only when the file itself does not fit the link |

A *measured-slow* link must never switch the quality policy: it is a throughput signal, so it may only
lower the ceiling. `MediaResolver` reads `serverState.isLimitedNetwork` for background-transfer gating,
but passes `isExpensive || isNetworkConstrained` as `isLimitedNetwork:` to the quality policy.

Details that matter:

- **The probe measures the body window, not the request.** Time to first byte (server latency, a
  transcode starting up) used to be counted as transfer time, which reported a healthy link as
  ~96 KB/s and capped Automatic to a 397 kbps transcode. A sample below 24 KB or with no measurable
  window now reports "unknown" instead of a rate, so Automatic stays as configured; a link that really
  cannot keep up still steps down through the underrun path.
- **Headroom**: 50 % of the measurement on a limited (metered/constrained) link, 80 % on an unmetered
  one — 2× headroom on Wi-Fi is what turned a ~1.7 Mbps measurement into a sub-lossless cap.
- **No ceiling when the file fits**: `streamingCeilingKbps` returns `nil` for Automatic when the
  source bitrate fits the measurement, so the server answers Direct Play instead of transcoding to a
  bitrate that merely sits under the measurement (`MaxStreamingBitrate` is what Jellyfin answers
  PlaybackInfo against).
- `[QUALITY]` logs one line per resolve with configured/source/measured/metered → format/ceiling, so
  "why is this lossy?" is answerable from a device log.

## Reachability: device route vs. server answer

`ServerState.isOnline` (from `NetworkMonitor`/`NWPathMonitor`) only says the device has a route. A
Wi-Fi link whose upstream is down still reports satisfied, and a server that is restarting answers
nothing while the device is perfectly connected. `ServerReachabilityMonitor` owns the second question:

| | |
|---|---|
| `ServerState.isServerReachable` | False when the active server does not answer |
| Probe | `ServerService.testConnection()` — one bounded `ping`, no retries |
| While reachable | one check every 20 s |
| While unreachable | one check every 3 s (that is what makes recovery automatic) |
| No device route | `isOnline == false` flips it immediately, no ping wasted |
| Foreground / "Try Again" | `checkNow()` |

Which surfaces read it:

- **Home, Discover, Recently Added, Artists, Albums, Favorites, Playlists** show
  `ServerUnreachableView` instead of their content (`MainTabView.reachabilityGated`).
- **Library, Downloads and Search are never gated**: they read the local index and the download
  store. `SearchViewModel.search(query:serverReachable:)` skips the catalog query while the server is
  away, answers from `LibraryIndexService` only (`isLocalOnly`), and `SearchView` re-runs the query —
  upgrading to a catalog search by itself — when the flag flips back.
- **Playback** keeps working from downloads/cache, and `CassetteApp` re-runs
  `playerService.handleNetworkRestored()` on both `isOnline` **and** `isServerReachable` transitions.

## Track hand-over invariant

`play()` flips `state.currentTrack`, `duration`, `position` and `isSeekable` to the incoming track
*before* resolving its source, and sets `isTrackTransitionPending`. While that flag is set the
progress ticker keeps running (it also drives scrobbling, prefetch and fade-out) but must not:

- write the outgoing engine's clock into `state.position` (`startProgressTimer`), or
- publish that clock to the lock screen (`periodicNowPlayingPush(elapsed:)`).

Resolving can wait on the network, so violating either rule showed the *previous* track's progress
under the new track's title for as long as the hand-over took. `[TRANSITION-TIMING]` logs report the
resolve time and the total hand-over time per skip; the throughput sample that `MediaResolver` takes
for Automatic quality runs inline only on the first resolve of a session — later tracks use the
cached rate and refresh it in the background, so a skip never waits on a measurement.

**A play request for the track that is already playing is ignored.** `play(tracks:startIndex:)` returns
early when the queue is unchanged, the scrubber is past 2 s and playback is `.playing`/`.loading`; the
early return logs the caller from `Thread.callStackSymbols` so a future duplicate can be traced. Without
that guard a re-issued request (a re-mounted list, a re-sent tap, a queue re-sync) tore the engine down
and restarted the song at 0:00 mid-track. Legitimate restarts are unaffected: they either carry a
different queue, start from the beginning of the track, or run through `resume()`/`skipToNext()`.

## Cover identity on playback surfaces

Every playback surface (full player, mini player, lyrics header, lock screen, theme colour) resolves
its artwork through `AppContainer.playbackCoverId(for:)`, in this order:

1. `explicitCoverArtId` — a manually chosen cover,
2. the id the album was **prepared** under (`AlbumCoverPreloadService.preparedCoverArtId(forAlbumId:)`)
   — that is the `{id}@hero` / `{id}@thumb` file a download or the library cover preload wrote to disk,
3. `effectiveCoverArtId` — the song's own media-file cover.

The bare song id is never used as a cover id: `getCoverArt?id=<songId>` is a different request from the
one the cache and the preloader use, so it could only ever miss the cover already on disk and re-fetch
it from the server.


## Platform support: iPhone, iPad, macOS

The project is a universal app (`TARGETED_DEVICE_FAMILY = "1,2"`, `UIRequiresFullScreen = NO`) with all
four iPad orientations, so iPadOS multitasking — Split View, Slide Over, Stage Manager — is allowed and
the app must stay correct at any column width.

`CassetteWideLayout` is the single place that decides which layout family applies:

| Surface | Rule |
|---|---|
| Detail / album / playlist | `usesDesktopDetail(horizontalSizeClass:)` — iPad regular width and macOS use the sidebar layout |
| Full player chrome | `usesWidePlayerLayout(horizontalSizeClass:verticalSizeClass:)` — iPad regular width *or* iPhone landscape |
| Content column | `cassetteContentWidth(.readable)` caps dense text at 640–1080 pt on macOS **and** iPad regular width |

Two rules that matter on iPad specifically:

- **Never derive layout from `UIScreen.main.bounds`.** On iPad that is the *device* width, not this
  view's width: in Split View a 1300 pt screen can hold a 320 pt column. Seed a first-frame value with a
  constant and correct it from the container's geometry on the first layout pass
  (`AlbumDetailView.heroHeight`), or cap the fallback (`LyricWordKaraokeLine`).
- **Live Activities have no Dynamic Island on iPad**, so the Lock Screen presentation is the one users
  see there. `LibraryPreparationLiveActivity` supplies both, and the artwork is re-rendered at
  presentation size for either.


A preparation pass (index rebuild + album artwork + cache invalidation) publishes one
`LibraryPreparationProgress` value; the in-app screen and the Live Activity render that same value
instead of each reaching into the index and cover services.

`LibraryPreparationLiveActivityController` (iOS only) starts an ActivityKit activity when a pass
begins — which is exactly when `LibraryPreparationView` goes on screen, satisfying Apple's
"a task the user is actively tracking" rule — updates it as progress moves (coalesced to one push
per 1.5 s, since ActivityKit budgets updates), and ends it on completion or failure. **Phase titles
are localized by the app** and travel inside `ContentState`: the widget extension has no string
catalogue of its own. The lock screen shows the cover currently being prepared via
`SharedWidgetData.image(forCoverArtId:)`, which reads `{id}.jpg` from the app-group `CoverArt`
directory. The app's own cache is a *different* store — `{id}@hero` inside the app container, which
the extension cannot read — so the pass bridges the cover it is about to display through
`WidgetSyncService.bridgeCoverArt`, and only while an activity is actually on screen.

Wiring requirements, easy to miss:

| Piece | Where |
|---|---|
| `NSSupportsLiveActivities` + `…FrequentUpdates` | `Cassette-Info.plist` (app target) |
| `ActivityConfiguration` | `fr.mathieu-dubart.CassetteWidgets/LibraryPreparation/`, registered in `CassetteWidgetsBundle` |
| Shared attributes visible to the extension | `Cassette/Shared/LibraryPreparationActivity.swift` — the app folder is a synchronized group, but the extension needs an explicit entry in `PBXFileSystemSynchronizedBuildFileExceptionSet` in `project.pbxproj` |

**Background continuation.** `BGProcessingTask` `app.cassette.library.preparation` is registered in
`CassetteApp` and submitted when a pass starts (`requestBackgroundContinuation` injected into
`LibraryPreparationService`). iOS decides when such a window runs — typically charging and idle — and
can expire it at any time, so this is *"resumes when allowed"*, not "always running in the
background". That is safe because the pass is resumable: every cover checks the disk first, so an
expired window loses no work and the next one continues from there. `BGTaskSchedulerPermittedIdentifiers`
lists the identifier.

Two ActivityKit rules that shape the code (both from Apple's `Activity.request` reference):

- **An activity can only be *started* while the app is in the foreground.** A background pass can only
  *update* an activity that already exists, so `isAppActive` (injected from `AppContainer`, keeping
  UIKit out of the Services layer) gates `Activity.request` and the attempt is logged instead of
  throwing.
- **Artwork larger than the presentation can prevent the activity from starting**, so the extension
  re-renders the cover at display size (`activityCoverImage`). The bridged covers are 600×600, which
  is larger than a 52 pt lock-screen thumbnail.

`reconcileOnLaunch()` ends activities left over from a previous run, which Apple asks apps to do
because the system can stop the app while an activity is live.

**Triggers.** A pass starts from three places, and the reporting lives in the pass itself so all of
them are followed identically:

| Trigger | Why |
|---|---|
| Launch-time change check (`RootView`) | The server reports a different file count than last time |
| Completed manual scan (`AccountSettingsView.startScan`) | The user just said "I added music", so waiting for the next launch would leave the index and artwork stale |
| `AlbumCoverPreloadService` cover pass | Onboarding's first download, a launch resuming one that was interrupted, and the manual download in storage settings |

The cover pass reports through `LibraryPreparationService.receiveExternalProgress`, so the Live
Activity, the localized phase title and the app-group artwork bridge stay in one place. A relaunch
whose previous cover pass did not finish (`snapshotStore.finishedFullPass == false`) re-runs it and
the preparation screen comes back with cover counts, because the launch reconcile already treats an
unfinished pass as a full pass. `prepareIfLibraryChanged` waits for a cover pass instead of skipping,
so a resume can never leave the index stale.

**An interrupted cover pass resumes; it does not restart.** The hero file on disk is the pass's
record of progress, so the batch loop queues only the covers that are missing
(`ArtworkImageCache.hasPreparedHeroCover` → `DownloadService.hasLocalCoverArt`, a filesystem probe)
and counts only those, which makes the progress bar, the `n / m` on the screen and the Live Activity
all describe the work that is actually left. The authoritative gate is unchanged:
`downloadOriginalAndCacheAsHero` still returns early when a hero file exists, so nothing can be
fetched twice even if the probe is wrong. When *nothing* is missing the pass reports no start at all,
so a no-op resume cannot put a Live Activity or the preparation screen in front of the user. The
probe matches the `{id}@hero` filename only; a cover stored under an older media-identity id is
queued conservatively, then satisfied from disk by the authoritative check.

`#if os(iOS)` guards mean the macOS build compiles the ActivityKit path down to nothing — only an
iOS build verifies it.

## Settings

`SettingsView` is the in-app hub (계정 / 재생 / 콘텐츠 / 앱), with detail screens in
`Cassette/Views/Settings/Screens`. Preferences live in `ObservableState` objects
that persist to `UserDefaults` (`cassette.streaming.*`, `cassette.cache.format`, …);
credentials live only in the Keychain. Retired preference values are migrated on
launch (`CacheFormat.migrateLegacyStoredValues`) instead of being silently dropped.

The system Settings bundle was removed in v1.1: its rows duplicated the in-app
screen, drifted from it, and the bundle was already excluded from the target.

## Localization

User-facing strings go through `Localizable.xcstrings` and `AppUILanguage`, which
resolves a locale-specific bundle at runtime so language changes apply without a
relaunch. Count strings use `CassetteCountLabel` rather than English pluralisation
(`"3 songs"` + `"s"` breaks Korean). `CassetteTests/AppLocalizationTests.swift`
guards coverage and formatting.

## Platform surfaces

| Surface | Location | Notes |
|---------|----------|-------|
| iOS app | `Cassette/Views/Platform/iOS` | Full player, lyrics surface, share sheet |
| macOS app | `Cassette/Views/Platform/macOS` | `CassetteSettingsScene`, menu commands; built in CI on every PR |
| Widgets | `fr.mathieu-dubart.CassetteWidgets` | Shares `Cassette/Shared/SharedNowPlayingState.swift` |
| App Intents / Siri | `Cassette/Siri` | Entities, intents, mappings, `SiriBridge` |
| Now Playing (iOS 27) | `Cassette/Services/Playback/CassetteMediaSessionController.swift` | `MediaSessionRepresentable` bridge |

## Testing

`CassetteTests` uses Swift Testing (`@Test` / `#expect`), one suite per concern, and
runs on a **macOS destination** — no simulator runtime required:

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

`CassetteUITests` covers only shell navigation; behavioural coverage is expected at
the unit level, where the seams (protocols + pure classifiers) make it cheap.

---

## Battery, thermal and performance budget

Every adaptive decision funnels through one value:
`CassettePerformance` (lock-free façade) → `PerformanceBudget` → `PerformanceGovernor`.

- **`PerformanceGovernor`** (`Cassette/Utilities/PerformanceGovernor.swift`, MainActor,
  `@Observable`) is the only type that reads system state: thermal state, Low Power Mode, memory
  warnings, the Reduce Motion setting, and the scene phase pushed from `CassetteApp`. It latches
  thermal **recovery** through `ThermalHysteresis` — degrade instantly, restore only after 20 s of
  a cool device — so a phone sitting on a thermal boundary cannot flap the UI between animated and
  flat every few seconds.
- **`PerformanceBudget`** is a pure `Sendable` value. `PerformanceBudget.make(...)` takes six
  scalars and derives every knob: decorative motion, beat visuals, Liquid Glass chrome, heavy
  artwork analysis, prefetch batch size + pacing, mesh frame interval, beat publish interval, and
  lyrics tick rate. Because it is pure, the whole policy is unit-tested
  (`CassetteTests/PerformanceBudgetTests.swift`).
- **Readers**: views read `governor.budget` inside `body` (Observation re-renders them on change);
  services, view models and the **audio render thread** read the statics on `CassettePerformance`
  (no lock, no actor hop, no `ProcessInfo` call per frame or per buffer).

| Signal | Chrome | Beat visuals | Artwork analysis | Bulk prefetch | Lyrics tick |
|---|---|---|---|---|---|
| cool, foreground, full power | animated | live | on | batches of 3 | 60 Hz / 30 Hz |
| `fair` thermal | animated | live | on | batches of 2 | 60 Hz / 30 Hz |
| Low Power / `serious` / `critical` | static | off | deferred (memoized colour) | 1 at a time, 2 s apart | 30 Hz / 20 Hz |
| backgrounded / memory warning | static | off | deferred | 1 at a time, padded | n/a |

One knob is deliberately **not** tied to Low Power Mode, because it is a playback behaviour rather
than polish: `allowsGaplessPrebuffer` (gapless, see above). Silence between tracks is not something
a listener trades away to save power, and an armed bridge normally reads an already-cached file;
only `critical` thermal pressure, memory pressure or a backgrounded app defer it.

Rules for new code:

1. Do not read `ProcessInfo` / `UIAccessibility` for throttling decisions in a view, view model or
   service. Add a knob to `PerformanceBudget` (with a test) so the policy stays in one place.
2. Degrade, don't break: when expensive work is skipped the UI falls back to a cached or cheap
   value (memoized colour, static gradient), never to an empty screen.
3. No `TEMP` kill switches. A feature that costs too much is throttled by the budget, it is not
   deleted from the product.

Verify on a device with Console.app (`subsystem: app.cassette.performance`): every budget change
logs one line, e.g. `thermal=serious lowPower=false active=false motion=false beat=false glass=false`.

---

## Known debt

### Playback state ownership after the first file decomposition

`PlayerService.swift` now holds 344 lines of stored state and dependency wiring. Its implementation
is split across 14 actor extensions, including engine, gapless, transition and iOS audio-session
files. State still has one actor owner; the move preserves execution order and generation guards.
Cross-file members are now module-internal, while file-local helpers remain private. This is an
explicit intermediate tradeoff: smaller responsibility files do not remove shared mutable state or
make the two playback engines interchangeable.

See [the refactor notes](SEARCH_AND_PLAYER_REFACTOR.md) for the file map, search paging changes and
validation. `AVPlayerPlaybackEngine` now owns native transport, next-item preparation, observations,
seek fencing and stall monitoring. Common transport uses `PlaybackEngine`; the AudioStreaming delegate
lives on its own subprotocol. Generation-tagged native events return to PlayerService for queue and
quality policy. Independent transition/session coordinators below remain follow-up work, with device
verification of transitions and interruptions.

The intended decomposition is by **state ownership**, not by line count:

| Target collaborator | Takes over | Needs from PlayerService |
|---------------------|-----------|--------------------------|
| `CrossfadeEngine` | fade-in/out tasks, volume ramp | engine volume handle, current source |
| `PlaybackSessionStore` | session persistence + restore | queue, position, resolved source |
| `NowPlayingPusher` | metadata/position pushes, artwork retry | now-playing service, current song |
| `AudioRouteCoordinator` | iOS audio session, interruptions, route migration | engine selection, resume policy |

Each extraction is one PR: introduce the collaborator behind its own protocol, move
the section, keep `PlayerServiceProtocol` unchanged, and verify on a device
(gapless transition, crossfade, interruption, session restore, Dolby playback)
before merging. The first seam is already taken: `AudioStreamingDelegate` moved to
`Cassette/Services/Playback/AudioStreamingDelegate.swift`, because it is the only
type in the file with zero access to actor-private state.
