// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension AlbumDetailContentView {
    // MARK: - Color loading

    func resolveDominantColor(coverArtId: String) async {
        // Initial preparation already extracted and persisted this exact cover's
        // page color. Use it directly, without decoding/analyzing the image again.
        if let palette = ColorCache.palette(for: coverArtId) {
            cacheAlbumPaletteAliases(palette, coverArtId: coverArtId)
            dominantColor = colorExtractor.colorOverride(for: coverArtId) ?? palette.background
            return
        }
        // Whole-cover majority color so the page body matches the cover's dominant hue.
        let cached = colorExtractor.cachedColor(for: coverArtId) ?? .clear
        if cached != .clear {
            dominantColor = cached
            if let palette = ColorCache.palette(for: coverArtId) {
                cacheAlbumPaletteAliases(palette, coverArtId: coverArtId)
            } else {
                // Older dominant-color entries predate the full palette cache. Backfill it
                // while this page is already covered by the resolved background color.
                await loadDominantColor(coverArtId: coverArtId)
            }
            return
        }
        await loadDominantColor(coverArtId: coverArtId)
    }

    private func loadDominantColor(coverArtId: String) async {
        let visibleImage = self.coverArtId == coverArtId ? effectiveInitialImage : nil
        let image = if let visibleImage { visibleImage }
            else { await container?.artworkImageCache.load(coverArtId: coverArtId) }
        guard let image else { return }
        let palette = await Task.detached(priority: .utility) {
            AlbumColorAnalyzer.generateArtworkPalette(from: image)
        }.value
        guard let palette, !Task.isCancelled else { return }
        cacheAlbumPaletteAliases(palette, coverArtId: coverArtId)
        // Replace provisional/legacy colors instead of retaining a stale gray cache hit.
        colorExtractor.storePreparedBackground(palette.packedBackground, for: coverArtId)
        let color = colorExtractor.colorOverride(for: coverArtId) ?? palette.background
        // Publish the final background before removing the loading cover.
        dominantColor = color
    }

    private func cacheAlbumPaletteAliases(_ palette: ArtworkPalette, coverArtId: String) {
        ColorCache.store(palette, for: coverArtId)
        // Some navigation paths only know the album id until the detail request returns.
        // Mirror the palette under that stable id as well, so the next visit can paint the
        // loading cover synchronously even when no cover-art id was supplied by the caller.
        if coverArtId != albumId {
            ColorCache.store(palette, for: albumId)
        }
    }
}
