# Album title fade — build 1013

The faded artwork presentation now starts darkening just above the album title. It gradually joins the content background through the title and artist, reaching the solid canvas below the metadata. The previous artist-only start in build 1012 has been superseded.

The gradient resolves title and metadata bounds from layout anchors, so multiline titles and larger accessibility text move the fade with the text. A solid fill below the gradient prevents the original artwork from reappearing. Uniform seamless and standard presentations retain their existing behavior.

Changed implementation: `FadedArtworkHero.swift`, `AlbumDetailView+Header.swift`, and `CassetteSpacing.swift`. Build number is 1013.

Validation completed:

- Generic iOS Simulator build succeeded for arm64 and x86_64 (`/tmp/cassette-1013-ios.log`).
- Native macOS `ArtworkPresentationTests` passed (`/tmp/cassette-1013-tests.log`). Pixel regressions cover widths 320, 390, and 430, multiline accessibility titles, fade continuity, subject scale, and the solid canvas below metadata.
- Inspected the rendered fixture at `/tmp/cassette-1013-artist-fade.png`. Blue and green guide lines belong only to the test fixture.
- `git diff --check` passed. Physical iPhone appearance has not been verified in this run.
