// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Uncropped sleeve on its exact edge color. No mask, rounded corners, border, or shadow:
/// a figure or title reaching the bottom of the artwork remains completely visible.
struct SeamlessArtworkHero: View {
    let coverArtId: String
    let initialImage: PlatformImage?
    let background: Color

    var body: some View {
        background
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero,
                             initialImage: initialImage, contentMode: .fit)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    let container = try! AppContainer(inMemory: true)
    SeamlessArtworkHero(coverArtId: "preview", initialImage: nil, background: .white)
        .frame(width: 320)
        .environment(container.artworkImageCache)
        .environment(\.appContainer, container)
}
