// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Observable
@MainActor
final class FullPlayerViewModel {
    var coverImage: PlatformImage? = nil
    var dominantColor: Color = .black
    var atmosphereTop: Color = .black
    var atmosphereMid: Color = .black
    var atmosphereBottom: Color = .black
    var isLightBackground: Bool = false
    /// Palette text stops (warm white chrome on dark Now Playing).
    var text1: Color = Color(red: 0.98, green: 0.97, blue: 0.95)
    var text2: Color = Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.86)
    var text3: Color = Color(red: 0.94, green: 0.93, blue: 0.90).opacity(0.68)
    var text4: Color = Color(red: 0.92, green: 0.91, blue: 0.88).opacity(0.50)

    /// Guards against slow cover loads painting a previous track’s theme onto the current one.
    private var colorUpdateGeneration = 0

    var contentColor: Color { text1 }
    var secondaryContentColor: Color { text2 }
    /// Frosted chrome behind glyphs. Avoid pure `Color.black` on dark covers — it reads as solid black
    /// holes against near-black themes. Light frost on dark / soft white frost on light keeps contrast.
    var glassTint: Color { isLightBackground ? Color.white.opacity(0.58) : Color.white.opacity(0.16) }

    func updateColors(for coverArtId: String?, colorExtractor: DominantColorExtractor, container: AppContainer?) async {
        let generation = colorUpdateGeneration + 1
        colorUpdateGeneration = generation

        guard let coverArtId else {
            withAnimation(CassetteAnimation.theme) {
                coverImage = nil
                dominantColor = .black
                atmosphereTop = .black
                atmosphereMid = .black
                atmosphereBottom = .black
                isLightBackground = false
                applyPaletteTexts(ArtworkColorTransformer.player(from: RawArtworkColorAnalysis(color: .black)))
            }
            return
        }

        // Theme the page INSTANTLY from the already-memoized dominant colour (it's cached app-wide by the cards /
        // mini player), so the background is coloured the moment the player opens — no black flash while the
        // cover downloads. Refined again once the artwork yields a player-atmosphere accent.
        let cachedColor = colorExtractor.cachedColor(for: coverArtId)
        if let cachedColor {
            withAnimation(CassetteAnimation.theme) {
                applyThemeColor(cachedColor)
            }
        }

        // Prefer the shared tiered artwork cache (ImageIO thumbnail) over a full JPEG decode.
        // iOS also keeps the image for the Apple Music–style blurred backdrop.
        var cachedImage = await container?.artworkImageCache.load(coverArtId: coverArtId, tier: .hero, allowNetwork: false)
        if cachedImage == nil {
            cachedImage = await container?.artworkImageCache.load(coverArtId: coverArtId, tier: .thumb, allowNetwork: false)
        }
        if cachedImage == nil {
            cachedImage = await container?.artworkImageCache.load(coverArtId: coverArtId, tier: .hero)
        }
        if let image = cachedImage {
            guard generation == colorUpdateGeneration else { return }
            // One k-means background extraction feeds both seeds. The page colour and the player
            // atmosphere seed are the same analysis, so this used to run the whole palette
            // pipeline twice per track change.
            // Under Low Power Mode / thermal pressure we reuse the memoized colour instead of
            // spending the CPU on a device that is already struggling.
            let skipAnalysis = cachedColor != nil && !CassettePerformance.allowsHeavyColorAnalysis
            let extracted: (page: Int?, player: Int?) = skipAnalysis
                ? (nil, nil)
                : await Task.detached(priority: .utility) { () -> (page: Int?, player: Int?) in
                    let background = DominantColorExtractor.packedAverageColor(from: image)
                    let page = cachedColor == nil ? background : nil
                    return (page, background)
                }.value
            guard generation == colorUpdateGeneration else { return }
            if cachedColor == nil, let page = extracted.page {
                _ = colorExtractor.storeColor(packed: page, for: coverArtId)
            }
            let seed: Color = {
                if let player = extracted.player {
                    return DominantColorExtractor.unpack(player)
                }
                return cachedColor ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
            }()
            withAnimation(CassetteAnimation.theme) {
                coverImage = image
                applyThemeColor(seed)
            }
            return
        }

        // Fallback: network URL when the shared cache missed (rare).
        let url: URL?
        if let localURL = await container?.downloadService.localCoverArtURL(forId: coverArtId) {
            url = localURL
        } else {
            url = await container?.libraryService.coverArtURL(id: coverArtId, size: 300)
        }
        guard generation == colorUpdateGeneration else { return }
        guard let url else { return }

        let data: Data
        if url.isFileURL {
            guard let localData = try? Data(contentsOf: url) else { return }
            data = localData
        } else {
            var request = URLRequest(url: url)
            if let serverService = container?.serverService,
               let credentials = try? await serverService.activeCredentials() {
                for (key, value) in credentials.customHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            guard let (networkData, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            data = networkData
        }
        guard generation == colorUpdateGeneration else { return }

        // Snapshot the policy on the MainActor so the detached closure stays free of global reads.
        let allowsHeavyAnalysis = CassettePerformance.allowsHeavyColorAnalysis
        let processed: (image: PlatformImage, page: Int?, player: Int?)? = await Task.detached(priority: .utility) {
            guard let image = PlatformImage(data: data) else { return nil }
            guard cachedColor == nil || allowsHeavyAnalysis else {
                // Constrained device: show the artwork, theme it from the memoized colour.
                return (image, nil, nil)
            }
            // Single extraction shared by both seeds (see the cached-image path above).
            let background = DominantColorExtractor.packedAverageColor(from: image)
            let page = cachedColor == nil ? background : nil
            return (image, page, background)
        }.value
        guard generation == colorUpdateGeneration, let processed else { return }
        if cachedColor == nil {
            _ = colorExtractor.storeColor(packed: processed.page, for: coverArtId)
        }
        let seed: Color = {
            if let player = processed.player {
                return DominantColorExtractor.unpack(player)
            }
            return cachedColor ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
        }()
        withAnimation(CassetteAnimation.theme) {
            coverImage = processed.image
            applyThemeColor(seed)
        }
    }

    /// Apple Music–style darkened atmosphere: readable warm-white lyrics, hue/chroma preserved.
    /// Uses the appearance-independent raw identity + the dedicated player dark remap.
    private func applyThemeColor(_ color: Color) {
        let palette = ArtworkColorTransformer.player(from: RawArtworkColorAnalysis(color: color))
        dominantColor = palette.base
        atmosphereTop = palette.top
        atmosphereMid = palette.mid
        atmosphereBottom = palette.bottom
        // Now Playing always uses light chrome on a darkened wash (like Music).
        isLightBackground = false
        applyPaletteTexts(palette)
    }

    private func applyPaletteTexts(_ palette: AppearanceColorPalette) {
        text1 = palette.text1
        text2 = palette.text2
        text3 = palette.text3
        text4 = palette.text4
    }
}
