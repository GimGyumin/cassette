// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import AppIntents

/// Apple Music–style square cover (continuous corners, subtle lift).
struct WidgetCoverArtView: View {
    let image: PlatformImage?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Circular play/pause control — matches Apple Music widget chrome (no text capsule).
struct WidgetPlayButton: View {
    let isPlaying: Bool
    var compact: Bool = false

    var body: some View {
        Button(intent: PlayPauseIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(compact ? .system(size: 12, weight: .bold) : .system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
    }
}

/// Soft tinted backdrop from the cover’s dominant color (AM-style, not a solid brand fill).
struct WidgetReadableBackground: View {
    let dominantColor: Color
    var image: PlatformImage? = nil

    private var isLightCover: Bool {
        guard let components = dominantColor.cgColor?.components, components.count >= 3 else { return false }
        let luminance = 0.299 * Double(components[0]) + 0.587 * Double(components[1]) + 0.114 * Double(components[2])
        return luminance > 0.6
    }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 28)
                    .scaleEffect(1.15)
                    .overlay(Color.black.opacity(isLightCover ? 0.45 : 0.35))
            } else {
                dominantColor
                if isLightCover {
                    Color.black.opacity(0.45)
                } else {
                    Color.black.opacity(0.2)
                }
            }
        }
    }
}
