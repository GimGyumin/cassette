# Passwordless Jellyfin sign-in

Quick Connect tokens are scoped to Jellyfin. They cannot authenticate OpenSubsonic requests. Password accounts continue using OpenSubsonic; accounts with an empty password and a Jellyfin token use `JellyfinMusicTransport`.

The adapter keeps SwiftSonic's existing domain-model contract so library, search, favorites, playlists, downloads, artwork and player consumers share one account route. It translates requests locally into Jellyfin calls and encodes the results in memory for the existing decoders. No request to `/rest/` is sent for a Quick Connect account. The placeholder API key is only an internal request-builder value; the real token is used by JellyfinClient and stored in Keychain.

A media URL resolver in the local SwiftSonic package routes AVPlayer, download and artwork URLs too. Original audio uses `Items/{id}/File` or `Download`; converted playback uses `Audio/{id}/universal`. An original cover request leaves MaxWidth unset. Canonical Navidrome IDs round-trip losslessly through the existing GUID codec, preserving downloaded-track identity.

Collection requests preserve search term, type, sorting, filters and offset. Requested pages are filled across a server's smaller page limit. Album tracks, artist albums, favorites and playlists page until complete. Removing a playlist track resolves its occurrence-specific PlaylistItemId, preserving other occurrences of the same song.

Authentication consumes each approval secret once. The exchange's User is reused; only servers omitting User require a follow-up user lookup. Token validation uses Users/Me before account persistence. Canceled/stale UI attempts cannot overwrite a newer attempt's state. Polling occurs every two seconds and ends on cancellation or expiry.

The sign-in UI uses a stable server-address step, a credentials step and a dedicated approval-code step. Secondary connection settings are in Other Sign-In Options. The back button stays inside the safe area, and all content scrolls with keyboard and accessibility text sizing.

## Protocol limits

This targets Navidrome's Jellyfin music API mounted under `/jellyfin`, including reverse-proxy path prefixes. It does not turn Cassette into a general-purpose Jellyfin video client. Unsupported Subsonic-only operations return an explicit unsupported error and never fall back to sending the Jellyfin token to Subsonic. Examples include playlist descriptions, internet-radio administration, server scanning and Subsonic queue persistence. The app's local playback-session persistence remains available. Jellyfin playback start/progress/stop reporting remains owned by PlayerService, avoiding duplicate Subsonic scrobbles.

## Sources

- [Navidrome Jellyfin API](https://github.com/navidrome/navidrome/blob/master/server/jellyfin/README.md)
- [Authentication token audience checks](https://github.com/navidrome/navidrome/blob/master/core/auth/auth.go)
- [Jellyfin playlist response and occurrence semantics](https://github.com/navidrome/navidrome/blob/master/server/jellyfin/playlists.go)

## Regression coverage

`JellyfinMusicTransportTests` exercises approval through account persistence and album retrieval, rejected tokens, paginated search, media routing/original artwork, duplicate playlist occurrences and lyric timestamp conversion using an isolated URLProtocol session. Outbound requests assert that neither `/rest/` nor a `jwt` query parameter is used. Real-server approval and playback still require a device acceptance test; mocked protocol tests cannot verify a live account or audio output.

## Validation (2026-09-28)

- macOS: 38 tests passed across JellyfinMusicTransportTests (8), OnboardingViewModelTests, ServerServiceTests and JellyfinFeatureClientTests. Final run: `/tmp/cassette-jellyfin-tests-verified.log`. No compiler warnings in that run.
- iOS Simulator arm64 build succeeded: `/tmp/cassette-jellyfin-ios.log`. The existing, documented iOS 27 MediaSession ConformanceIsolation warning remains; no new warnings.
- A prior test-result export hit disk exhaustion; it is not counted as a passing validation. The final run disabled system diagnostic collection and completed successfully.
- No live Quick Connect account was authorized by the agent, and no actual-device audio or UI acceptance test was performed.
