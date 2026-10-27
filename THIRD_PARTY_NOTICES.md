# Third-party code incorporated in this working tree

## Apple Music Like Lyrics (AMLL)

- Upstream: https://github.com/amll-dev/applemusic-like-lyrics
- Revision: `5fee356362353dbb24ce9bea3a62536478040de7`
- License: **AGPL-3.0-only**
- Copyright: the AMLL contributors; Swift adaptation © 2026 Cassette contributors.
- Swift port: `Cassette/Utilities/AMLL/`.
- Derived conformance tests/vectors: `CassetteTests/AMLLPortTests.swift` and `CassetteTests/Fixtures/amll-reference.json`.
- Full license: [`Cassette/Resources/Licenses/AMLL-AGPL-3.0.txt`](Cassette/Resources/Licenses/AMLL-AGPL-3.0.txt).
- Source-to-port mapping and platform adaptations: [`docs/fixes/2026-10-26-amll-swift-port.md`](docs/fixes/2026-10-26-amll-swift-port.md).
- Dynamic artwork: `bg-render/pixi-renderer.ts` sprite motion is adapted in `AMLLArtworkMotion.swift`, with native layer compositing in `LyricsArtwork.metal`. Native GPU blur, color management and lifecycle integration are described in `docs/fixes/2026-10-26-amll-background.md`.

The port is not relicensed under the root MPL license. Existing Cassette MPL notices remain in place. This notice grants no exception to the AGPL terms for the combined application.

