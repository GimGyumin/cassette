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
    private static let defaultsKey = "cassette.artworkPalette.cache.v7"
    private static let lock = NSLock()
    private static var memory: [String: CachedPalette] = [:]

    struct CachedPalette: Codable, Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        if let cached = memory[id] { return cached.asArtworkPalette() }
        guard let dict = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let data = dict[id] as? Data,
              let cached = try? JSONDecoder().decode(CachedPalette.self, from: data) else {
            return nil
        }
        memory[id] = cached
        return cached.asArtworkPalette()
    }

    static func store(_ palette: ArtworkPalette, for id: String) {
        guard !id.isEmpty, let cached = CachedPalette.from(palette) else { return }
        lock.lock()
        memory[id] = cached
        lock.unlock()
        var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        if let data = try? JSONEncoder().encode(cached) {
            dict[id] = data
            UserDefaults.standard.set(dict, forKey: defaultsKey)
        }
    }

    static func clear() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

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

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
