// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import CoreImage
import OSLog

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Extracts the dominant color from cover art by **pixel proportion** (most frequent quantized
/// color), not a washed-out area average. Results are cached in memory keyed by coverArtId and
/// persisted to UserDefaults as packed 0xRRGGBB integers so colors are available at cold start.
///
/// TODO(v2.0): UserDefaults is used intentionally here for two reasons:
///   1. Synchronous cold-start hydration in init() — SwiftData requires async context.
///   2. cachedColors() feeds WidgetSyncService for App Group sharing, which UserDefaults
///      handles natively across process boundaries. Migrating requires an async init
///      refactor and a separate widget-sync write path.
@MainActor
@Observable
final class DominantColorExtractor {
    // v17: distinguish white sleeves with dark subjects from genuinely silver artwork.
    private static let userDefaultsKey = "cassette.dominantColor.cache.v17"
    private static let legacyUserDefaultsKeys = [
        "cassette.dominantColor.cache.v16",
        "cassette.dominantColor.cache.v15",
        "cassette.dominantColor.cache.v14",
        "cassette.dominantColor.cache.v13",
        "cassette.dominantColor.cache.v12",
        "cassette.dominantColor.cache.v11",
        "cassette.dominantColor.cache.v10",
        "cassette.dominantColor.cache.v9",
        "cassette.dominantColor.cache.v8",
        "cassette.dominantColor.cache.v7",
        "cassette.dominantColor.cache.v6",
        "cassette.dominantColor.cache.v5",
        "cassette.dominantColor.cache.v4",
        "cassette.dominantColor.cache.v3",
        "cassette.dominantColor.cache.v2",
    ]
    /// User-picked colour overrides (per coverArtId).
    private static let overridesKey = "cassette.dominantColor.overrides"

    // Pure memoization store — not UI state. @ObservationIgnored so a cache write (on a cold-cover miss)
    // never invalidates a view that called dominantColor() during its body. Colors that drive UI flow
    // through observed @State / view-model properties (e.g. FullPlayerViewModel.dominantColor), never this.
    @ObservationIgnored private var cache: [String: Color] = [:]
    /// Packed mirror of `cache`. Keeping it in memory avoids decoding and re-encoding the entire
    /// UserDefaults dictionary for every cover processed during a library preload.
    @ObservationIgnored private var packedCache: [String: Int] = [:]
    /// Coalesces a burst of cover analyses into one persistence write.
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    /// Bottom-strip (lower 20%) colours — the ARTIST hero only. Keyed by coverArtId but DISTINCT from `cache`, so
    /// one cover can hold both a whole-image dominant (album/player) and a bottom-strip colour (artist) with no
    /// clobber. In-memory only — re-extracted per launch, never mirrored to widgets.
    @ObservationIgnored private var bottomStripCache: [String: Color] = [:]
    /// User-picked colour overrides (per coverArtId), persisted, taking precedence over the extracted dominant.
    /// OBSERVED (unlike `cache`) so themed surfaces re-render the instant the user changes a colour.
    private var colorOverrides: [String: Color] = [:]
    /// Appearance-independent raw artwork analysis, keyed by coverArtId. Kept in memory only:
    /// the persistent layer still stores the packed background 0xRRGGBB (the raw identity seed),
    /// from which `RawArtworkColorAnalysis(color:)` can be rebuilt without re-running image analysis.
    @ObservationIgnored private var rawAnalysisCache: [String: RawArtworkColorAnalysis] = [:]

    init() {
        for key in Self.legacyUserDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Drop pre–matte-black palette entries.
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v1")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v2")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v3")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v4")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v5")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v6")
        UserDefaults.standard.removeObject(forKey: "cassette.artworkPalette.cache.v7")
        let stored = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) ?? [:]
        var hydrated: [String: Color] = [:]
        hydrated.reserveCapacity(stored.count)
        for (key, value) in stored {
            if let packed = value as? Int {
                hydrated[key] = Self.unpack(packed)
                packedCache[key] = packed
            }
        }
        cache = hydrated

        let storedOverrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) ?? [:]
        var hydratedOverrides: [String: Color] = [:]
        for (key, value) in storedOverrides {
            if let packed = value as? Int { hydratedOverrides[key] = Self.unpack(packed) }
        }
        colorOverrides = hydratedOverrides
        Logger.dominantColor.debug("Hydrated \(hydrated.count) dominant colors + \(hydratedOverrides.count) overrides.")
    }

    /// Returns the dominant color for the given image, or Color.clear if unavailable.
    /// Checks the in-memory cache (hydrated from UserDefaults at launch) before processing.
    func dominantColor(for coverArtId: String?, image: PlatformImage?) -> Color {
        guard let coverArtId else { return .clear }
        if let override = colorOverrides[coverArtId] { return override }
        if let cached = cache[coverArtId] { return cached }
        guard let image else { return .clear }
        guard let result = extract(from: image) else { return .clear }
        cache[coverArtId] = result.color
        persistColor(result.packed, forKey: coverArtId)
        ColorCache.store(result.palette, for: coverArtId)
        return result.color
    }

    /// Bottom-strip (lower 20%) majority color — the ARTIST hero only. An artist photo's whole-image
    /// majority can be a bright face; its bottom edge (what melts into the body) is the tone the hero
    /// needs for a seamless meet. Override-first like `dominantColor`, cached separately.
    func bottomStripColor(for coverArtId: String?, image: PlatformImage?) -> Color {
        guard let coverArtId else { return .clear }
        if let override = colorOverrides[coverArtId] { return override }
        if let cached = bottomStripCache[coverArtId] { return cached }
        guard let image else { return .clear }
        guard let result = extract(from: image, bottomStrip: true) else { return .clear }
        bottomStripCache[coverArtId] = result.color
        return result.color
    }

    /// Synchronously returns the memoized color for an id, or nil if not yet extracted. No work.
    func cachedColor(for coverArtId: String) -> Color? {
        colorOverrides[coverArtId] ?? cache[coverArtId]
    }

    /// Synchronously returns the memoized raw analysis for an id, or nil if not yet analyzed.
    /// No artwork work is performed.
    func cachedRawAnalysis(for coverArtId: String) -> RawArtworkColorAnalysis? {
        rawAnalysisCache[coverArtId]
            ?? cache[coverArtId].map { RawArtworkColorAnalysis(color: $0) }
    }

    /// Appearance-independent analysis of an artwork image, cached after first extraction.
    /// Does NOT apply manual color override — that is the caller's concern.
    func rawAnalysis(for coverArtId: String, image: PlatformImage?) -> RawArtworkColorAnalysis? {
        if let hit = rawAnalysisCache[coverArtId] { return hit }
        guard let image, let result = AlbumColorAnalyzer.analyze(from: image) else {
            return cache[coverArtId].map { RawArtworkColorAnalysis(color: $0) }
        }
        rawAnalysisCache[coverArtId] = result.raw
        return result.raw
    }

    /// The user-picked colour override for a cover, if any (nil → the extracted dominant is used).
    func colorOverride(for coverArtId: String) -> Color? { colorOverrides[coverArtId] }

    /// Set (or clear) the override for SEVERAL cover ids at once. An album cover and its songs can carry
    /// distinct cover-art ids for the SAME artwork (e.g. "al-…" vs "mf-…" on Navidrome), so the user's pick is
    /// stored under all of them — the full player (keyed on the song's id) then resolves it too. One persist.
    func setColorOverride(_ color: Color?, forIds ids: [String]) {
        let packed = color.flatMap(Self.pack)
        var dict = UserDefaults.standard.dictionary(forKey: Self.overridesKey) ?? [:]
        for id in ids where !id.isEmpty {
            if let color {
                colorOverrides[id] = color
                if let packed { dict[id] = packed }
            } else {
                colorOverrides.removeValue(forKey: id)
                dict.removeValue(forKey: id)
            }
        }
        UserDefaults.standard.set(dict, forKey: Self.overridesKey)
    }

    /// Resolves a SwiftUI Color to a packed 0xRRGGBB int (sRGB) for persistence; nil if it can't be resolved.
    private static func pack(_ color: Color) -> Int? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #elseif canImport(AppKit)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        #endif
        return (Int(max(0, min(1, r)) * 255) << 16) | (Int(max(0, min(1, g)) * 255) << 8) | Int(max(0, min(1, b)) * 255)
    }

    /// Stores a packed color produced off-main by `packedAverageColor(from:)` and returns the Color,
    /// so callers that already extracted off the main actor don't repeat the work here.
    func storeColor(packed: Int?, for coverArtId: String) -> Color {
        if let cached = cache[coverArtId] { return cached }
        guard let packed else { return .clear }
        let color = Self.unpack(packed)
        cache[coverArtId] = color
        persistColor(packed, forKey: coverArtId)
        return color
    }

    /// The preload's saved palette is authoritative, including when an older
    /// thumbnail analysis already populated this cache. Manual overrides stay separate.
    func storePreparedBackground(_ packed: Int, for coverArtId: String) {
        cache[coverArtId] = Self.unpack(packed)
        rawAnalysisCache.removeValue(forKey: coverArtId)
        persistColor(packed, forKey: coverArtId)
    }

    /// Finish persistence before declaring initial asset preparation complete.
    /// Normal on-demand writes remain coalesced to avoid a write per image.
    func persistPreparedBackgrounds() {
        persistenceTask?.cancel()
        persistenceTask = nil
        UserDefaults.standard.set(packedCache, forKey: Self.userDefaultsKey)
    }

    /// Stores a bottom-strip packed color in the in-memory artist/album hero cache (not the whole-image
    /// dominant used by the full player / widgets).
    func storeBottomStripColor(packed: Int?, for coverArtId: String) -> Color {
        if let cached = bottomStripCache[coverArtId] { return cached }
        guard let packed else { return .clear }
        let color = Self.unpack(packed)
        bottomStripCache[coverArtId] = color
        return color
    }

    /// Off-main majority-color extraction (packed 0xRRGGBB). `nonisolated` so it runs inside `Task.detached`.
    nonisolated static func packedAverageColor(from image: PlatformImage) -> Int? {
        AlbumColorAnalyzer.packedBackground(from: image, bottomStrip: false)
    }

    /// Off-main bottom-strip majority color used by artist heroes (lower 20% of the cover).
    nonisolated static func packedBottomStripAverageColor(from image: PlatformImage) -> Int? {
        AlbumColorAnalyzer.packedBackground(from: image, bottomStrip: true)
    }

    /// Returns all persisted packed 0xRRGGBB colors keyed by coverArtId.
    /// Used by WidgetSyncService to mirror the cache to the App Group shared container.
    func cachedColors() -> [String: Int] {
        packedCache
    }

    func invalidate(for coverArtId: String?) {
        guard let coverArtId else { return }
        cache.removeValue(forKey: coverArtId)
        removePersistedColor(forKey: coverArtId)
    }

    func clearCache() {
        persistenceTask?.cancel()
        persistenceTask = nil
        cache.removeAll()
        packedCache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        ColorCache.clear()
    }

    // MARK: - Private

    static func unpack(_ packed: Int) -> Color {
        Color(
            red: Double((packed >> 16) & 0xFF) / 255.0,
            green: Double((packed >> 8) & 0xFF) / 255.0,
            blue: Double(packed & 0xFF) / 255.0
        )
    }

    private func persistColor(_ packed: Int, forKey key: String) {
        packedCache[key] = packed
        schedulePersistence()
    }

    private func removePersistedColor(forKey key: String) {
        packedCache.removeValue(forKey: key)
        schedulePersistence()
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.set(self.packedCache, forKey: Self.userDefaultsKey)
            self.persistenceTask = nil
        }
    }

    private func extract(from image: PlatformImage, bottomStrip: Bool = false) -> (color: Color, packed: Int, palette: ArtworkPalette)? {
        guard let palette = AlbumColorAnalyzer.generateArtworkPalette(from: image, bottomStrip: bottomStrip) else {
            return nil
        }
        return (
            color: Self.unpack(palette.packedBackground),
            packed: palette.packedBackground,
            palette: palette
        )
    }

    /// Full `ArtworkPalette` (cached). Falls back to analyzer when missed.
    nonisolated static func artworkPalette(for coverArtId: String?, image: PlatformImage?) -> ArtworkPalette? {
        if let coverArtId, let cached = ColorCache.palette(for: coverArtId) {
            return cached
        }
        guard let image, let palette = AlbumColorAnalyzer.generateArtworkPalette(from: image) else { return nil }
        if let coverArtId {
            ColorCache.store(palette, for: coverArtId)
        }
        return palette
    }
}
