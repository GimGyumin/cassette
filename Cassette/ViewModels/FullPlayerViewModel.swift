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
    private(set) var coverImageId: String? = nil
    var dominantColor: Color = .black
    var atmosphereTop: Color = .black
    var atmosphereMid: Color = .black
    var atmosphereBottom: Color = .black
    var isLightBackground: Bool = false
    /// Palette text stops (warm white chrome on dark Now Playing).
    let text1: Color = Color(red: 0.98, green: 0.97, blue: 0.95)
    var text2: Color = Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.86)
    var text3: Color = Color(red: 0.94, green: 0.93, blue: 0.90).opacity(0.68)
    var text4: Color = Color(red: 0.92, green: 0.91, blue: 0.88).opacity(0.50)

    /// Guards against slow cover loads painting a previous track’s theme onto the current one.
    @ObservationIgnored private var colorUpdateGeneration = 0
    private struct ThemeKey: Equatable {
        let coverID: String
        let serverID: UUID?
        let override: Color?
        let uploadVersion: Int
    }
    @ObservationIgnored private var visibleTheme: ThemeKey?
    @ObservationIgnored private var preparedTheme: ThemeKey?
    @ObservationIgnored private var artworkObserver: NSObjectProtocol?
    private(set) var artworkRevision: UInt64 = 0

    init() {
        artworkObserver = NotificationCenter.default.addObserver(
            forName: OriginalArtwork.didInstall, object: nil, queue: .main
        ) { [weak self] notification in
            let coverID = notification.object as? String
            Task { @MainActor [weak self] in
                guard let self, coverID == self.visibleTheme?.coverID else { return }
                self.preparedTheme = nil
                self.colorUpdateGeneration &+= 1
                self.artworkRevision &+= 1
            }
        }
    }

    isolated deinit {
        if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) }
    }

    func themeColor(for coverID: String, serverID: UUID?) -> Color? {
        guard visibleTheme?.coverID == coverID, visibleTheme?.serverID == serverID else { return nil }
        return dominantColor
    }

    func resetTheme() {
        colorUpdateGeneration &+= 1
        visibleTheme = nil
        preparedTheme = nil
        coverImage = nil
        coverImageId = nil
        applyThemeColor(.black)
    }

    var contentColor: Color { text1 }
    var secondaryContentColor: Color { text2 }
    /// Frosted chrome behind glyphs. Avoid pure `Color.black` on dark covers — it reads as solid black
    /// holes against near-black themes. Light frost on dark / soft white frost on light keeps contrast.
    var glassTint: Color { isLightBackground ? Color.white.opacity(0.58) : Color.white.opacity(0.16) }

    func coverImage(for coverArtId: String) -> PlatformImage? {
        coverImageId == coverArtId ? coverImage : nil
    }

    func updateColors(for coverArtId: String?, colorExtractor: DominantColorExtractor, container: AppContainer?, uploadVersion: Int = 0) async {
        guard !Task.isCancelled else { return }
        let key = coverArtId.map {
            ThemeKey(coverID: $0, serverID: container?.serverState.activeServer?.id,
                     override: colorExtractor.colorOverride(for: $0), uploadVersion: uploadVersion)
        }
        if let key, preparedTheme == key, coverImage(for: key.coverID) != nil { return }
        let generation = colorUpdateGeneration + 1
        colorUpdateGeneration = generation
        preparedTheme = nil

        guard let coverArtId else {
            withAnimation(CassetteAnimation.theme) { resetTheme() }
            return
        }
        if visibleTheme?.coverID != key?.coverID || visibleTheme?.serverID != key?.serverID {
            coverImage = nil
            coverImageId = nil
            applyThemeColor(.black)
        }
        visibleTheme = key

        // Theme the page INSTANTLY from the already-memoized dominant colour (it's cached app-wide by the cards /
        // mini player), so the background is coloured the moment the player opens — no black flash while the
        // cover downloads. Refined again once the artwork yields a player-atmosphere accent.
        let cachedColor = colorExtractor.colorOverride(for: coverArtId)
            ?? ColorCache.palette(for: coverArtId)?.background
            ?? colorExtractor.cachedColor(for: coverArtId)
        if let cachedColor {
            applyThemeColor(cachedColor)
        }

        if let image = container?.artworkImageCache.cachedImage(for: coverArtId, tier: .hero)
            ?? container?.artworkImageCache.cachedImage(for: coverArtId, tier: .thumb) {
            coverImage = image
            coverImageId = coverArtId
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
            // A prepared palette is valid on a cool device too. Reopening the player
            // or changing tracks on the same album must not repeat image clustering.
            let skipAnalysis = ColorCache.palette(for: coverArtId) != nil
                || colorExtractor.colorOverride(for: coverArtId) != nil
            let extracted: (page: Int?, player: Int?) = skipAnalysis
                ? (nil, nil)
                : await Task.detached(priority: .utility) { () -> (page: Int?, player: Int?) in
                    let palette = AlbumColorAnalyzer.generateArtworkPalette(from: image)
                    if let palette { ColorCache.store(palette, for: coverArtId) }
                    return (palette?.packedBackground, palette?.packedBackground)
                }.value
            guard generation == colorUpdateGeneration, !Task.isCancelled else { return }
            if let page = extracted.page {
                colorExtractor.storePreparedBackground(page, for: coverArtId)
            }
            let seed: Color = {
                if let override = colorExtractor.colorOverride(for: coverArtId) { return override }
                if let player = extracted.player {
                    return DominantColorExtractor.unpack(player)
                }
                return cachedColor ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
            }()
            coverImage = image
            coverImageId = coverArtId
            applyThemeColor(seed)
            preparedTheme = key
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
            let localData = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let localData, !Task.isCancelled else { return }
            data = localData
        } else {
            var request = URLRequest(url: url)
            ArtworkNetworkPolicy.apply(to: &request)
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

        let processed: (image: PlatformImage, page: Int?, player: Int?)? = await Task.detached(priority: .utility) {
            guard let image = ArtworkImageCache.thumbnailImage(from: data, maxDimension: ArtworkTier.hero.decodePixels) else { return nil }
            guard ColorCache.palette(for: coverArtId) == nil, key?.override == nil else {
                return (image, nil, nil)
            }
            // Single extraction shared by both seeds (see the cached-image path above).
            let palette = AlbumColorAnalyzer.generateArtworkPalette(from: image)
            if let palette { ColorCache.store(palette, for: coverArtId) }
            return (image, palette?.packedBackground, palette?.packedBackground)
        }.value
        guard generation == colorUpdateGeneration, !Task.isCancelled, let processed else { return }
        if let packed = processed.page {
            colorExtractor.storePreparedBackground(packed, for: coverArtId)
        }
        let seed: Color = {
            if let override = colorExtractor.colorOverride(for: coverArtId) { return override }
            if let player = processed.player {
                return DominantColorExtractor.unpack(player)
            }
            return cachedColor ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
        }()
        coverImage = processed.image
        coverImageId = coverArtId
        applyThemeColor(seed)
        preparedTheme = key
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
        // The GPU wash already controls background luminance. Keep the primary title
        // identical before/after artwork preparation and across player/lyrics surfaces.
        text2 = palette.text2
        text3 = palette.text3
        text4 = palette.text4
    }
}
