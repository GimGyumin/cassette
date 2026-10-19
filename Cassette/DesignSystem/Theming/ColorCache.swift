// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftUI

/// Process-local + UserDefaults cache for artwork palettes keyed by cover / album id.
/// `DominantColorExtractor` remains the UI-facing store; this cache avoids re-running
/// `AlbumColorAnalyzer` when a full `ArtworkPalette` is needed repeatedly.
nonisolated enum ColorCache {
    private static let cache = ArtworkPaletteCache(
        load: { UserDefaults.standard.dictionary(forKey: "cassette.artworkPalette.cache.v8") as? [String: Data] ?? [:] },
        persist: { UserDefaults.standard.set($0, forKey: "cassette.artworkPalette.cache.v8") }
    )

    struct CachedPalette: Codable, Sendable, Equatable {
        let packedBackground: Int
        let packedText1: Int
        let packedText2: Int
        let packedText3: Int
        let packedText4: Int

        func asArtworkPalette() -> ArtworkPalette {
            ArtworkPalette(
                background: unpack(packedBackground),
                text1: unpack(packedText1),
                text2: unpack(packedText2),
                text3: unpack(packedText3),
                text4: unpack(packedText4),
                packedBackground: packedBackground
            )
        }

        static func from(_ palette: ArtworkPalette) -> CachedPalette? {
            guard let t1 = pack(palette.text1),
                  let t2 = pack(palette.text2),
                  let t3 = pack(palette.text3),
                  let t4 = pack(palette.text4) else { return nil }
            return CachedPalette(
                packedBackground: palette.packedBackground,
                packedText1: t1,
                packedText2: t2,
                packedText3: t3,
                packedText4: t4
            )
        }
    }

    static func palette(for id: String) -> ArtworkPalette? {
        cache.palette(for: id)?.asArtworkPalette()
    }

    static func store(_ palette: ArtworkPalette, for id: String) {
        guard !id.isEmpty, let cached = CachedPalette.from(palette) else { return }
        cache.store(cached, for: id)
    }

    static func clear() { cache.clear() }

    static func persistPreparedPalettes() async { await cache.flush() }

    private static func unpack(_ packed: Int) -> Color {
        Color(
            red: Double((packed >> 16) & 0xFF) / 255.0,
            green: Double((packed >> 8) & 0xFF) / 255.0,
            blue: Double(packed & 0xFF) / 255.0
        )
    }

    private static func pack(_ color: Color) -> Int? {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Int(max(0, min(1, r)) * 255) << 16)
            | (Int(max(0, min(1, g)) * 255) << 8)
            | Int(max(0, min(1, b)) * 255)
        #elseif canImport(AppKit)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (Int(max(0, min(1, rgb.redComponent)) * 255) << 16)
            | (Int(max(0, min(1, rgb.greenComponent)) * 255) << 8)
            | Int(max(0, min(1, rgb.blueComponent)) * 255)
        #else
        return nil
        #endif
    }
}

/// All external persistence and palette coding runs outside the memory lock. The
/// serial writer snapshots revisions so an old delayed write cannot undo a clear.
nonisolated final class ArtworkPaletteCache: @unchecked Sendable {
    typealias Palette = ColorCache.CachedPalette
    private let lock = NSLock()
    private var memory: [String: Palette] = [:]
    private var stored: [String: Data]?
    private var revision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var pendingWrite: DispatchWorkItem?
    private let persistenceQueue = DispatchQueue(label: "app.cassette.palette-persistence", qos: .utility)
    private let load: @Sendable () -> [String: Data]
    private let persist: @Sendable ([String: Data]) -> Void

    init(load: @escaping @Sendable () -> [String: Data],
         persist: @escaping @Sendable ([String: Data]) -> Void) {
        self.load = load
        self.persist = persist
    }

    func palette(for id: String) -> Palette? {
        if let cached = lock.withLock({ memory[id] }) { return cached }
        hydrate()
        guard let data = lock.withLock({ stored?[id] }),
              let cached = try? JSONDecoder().decode(Palette.self, from: data) else { return nil }
        lock.withLock {
            if stored?[id] == data { memory[id] = cached }
        }
        return cached
    }

    func store(_ palette: Palette, for id: String) {
        guard !id.isEmpty, lock.withLock({ memory[id] != palette }) else { return }
        hydrate()
        // Legacy JSON dictionaries need not have the same key order as a newly
        // encoded value. Compare the palette before deciding that disk is dirty.
        if let previous = lock.withLock({ stored?[id] }),
           (try? JSONDecoder().decode(Palette.self, from: previous)) == palette {
            let unchanged = lock.withLock {
                guard stored?[id] == previous else { return false }
                memory[id] = palette
                return true
            }
            if unchanged { return }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(palette) else { return }
        lock.withLock {
            guard memory[id] != palette else { return }
            memory[id] = palette
            guard stored?[id] != data else { return }
            stored?[id] = data
            revision &+= 1
            schedulePersistenceLocked()
        }
    }

    func clear() {
        lock.withLock {
            memory.removeAll()
            stored = [:]
            revision &+= 1
            schedulePersistenceLocked()
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            persistenceQueue.async {
                self.persistSnapshot()
                continuation.resume()
            }
        }
    }

    private func hydrate() {
        guard lock.withLock({ stored == nil }) else { return }
        // UserDefaults may synchronously notify observers. Never hold our lock here,
        // including on a cold miss. A concurrent clear/store wins over this disk read.
        let loaded = load()
        lock.withLock {
            if stored == nil { stored = loaded }
        }
    }

    private func schedulePersistenceLocked() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSnapshot() }
        pendingWrite = work
        persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistSnapshot() {
        let snapshot: (data: [String: Data], revision: UInt64)? = lock.withLock {
            pendingWrite?.cancel()
            pendingWrite = nil
            guard revision != persistedRevision else { return nil }
            return (stored ?? [:], revision)
        }
        guard let snapshot else { return }
        persist(snapshot.data)
        lock.withLock { persistedRevision = snapshot.revision }
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
