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

/// Apple Music–style cover atmosphere: vertical gradient + soft material veil.
struct CoverAtmosphereBackground: View {
    let top: Color
    let mid: Color
    let bottom: Color
    var isThemed: Bool
    var isLight: Bool = false

    private var systemBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        Group {
            if isThemed {
                ZStack {
                    LinearGradient(
                        colors: [top, mid, bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // Soft material so Liquid Glass / chrome blend like Music.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(isLight ? 0.22 : 0.14)
                        .allowsHitTesting(false)
                }
            } else {
                systemBackground
            }
        }
        .ignoresSafeArea()
        .animation(CassetteAnimation.theme, value: isThemed)
        .animation(CassetteAnimation.theme, value: top)
    }
}

/// Album page backdrop: Apple Music–style ambient radial glow. The brightest, most
/// chromatic tone sits behind the title (upper third) and falls off to a deeper, stable
/// tone at the edges/bottom — reproducing Music's "center energy" rather than a flat fill.
struct AlbumAtmosphereBackground: View {
    let atmosphere: AlbumAtmosphere

    private var systemBackground: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        Group {
            if atmosphere.isThemed {
                // Solid page tone — matches ImmersiveCoverHero's meltTargetColor so the
                // album cover region and the top/bottom body read as one continuous color
                // with no gradient seam.
                atmosphere.pageColor
            } else {
                systemBackground
            }
        }
        .ignoresSafeArea()
        .animation(CassetteAnimation.theme, value: atmosphere.isThemed)
        .animation(CassetteAnimation.theme, value: atmosphere.pageColor)
    }
}
