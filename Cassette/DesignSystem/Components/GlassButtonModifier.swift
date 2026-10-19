// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

private enum CassetteGlassStyle {
    /// Adaptive frosted tint that stays visible in dark mode (near-black chrome) and light mode.
    /// Uses `.primary` so it inverts with the color scheme — white frost on dark, dark frost on light.
    static var defaultTint: Color { Color.primary.opacity(0.20) }
    /// Brand red glass for primary CTAs (OK / Play / prominent actions).
    static var accentTint: Color { CassetteColors.accent.opacity(0.72) }
}

extension View {
    /// Circular control (HIG-sized tap target). Uses Liquid Glass only when
    /// `CassettePerformance.preferCheapChrome` is false — otherwise a flat fill so
    /// compositor work cannot starve AudioStreaming.
    @ViewBuilder
    func cassetteGlassButton(size: CGFloat = 44, tint: Color? = nil) -> some View {
        let resolved = tint ?? CassetteGlassStyle.defaultTint
        let usesExplicitTint = tint != nil
        if !CassettePerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(
                    usesExplicitTint ? Glass.clear.tint(resolved) : Glass.regular,
                    in: .circle
                )
        } else {
            self
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background {
                    Circle()
                        .fill(resolved)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                }
        }
    }

    /// Capsule control. Same cheap-chrome gate as `cassetteGlassButton`.
    @ViewBuilder
    func cassetteGlassCapsule(tint: Color? = nil) -> some View {
        let resolved = tint ?? CassetteGlassStyle.defaultTint
        let usesExplicitTint = tint != nil
        if !CassettePerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self
                .contentShape(Capsule())
                .glassEffect(
                    usesExplicitTint ? Glass.clear.tint(resolved) : Glass.regular,
                    in: .capsule
                )
        } else {
            self.background {
                Capsule()
                    .fill(resolved)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    /// Primary CTA capsule with Cassette Red tint.
    func cassetteAccentGlassCapsule(disabled: Bool = false) -> some View {
        cassetteGlassCapsule(tint: CassetteColors.accent.opacity(disabled ? 0.35 : 0.72))
    }
}

extension View {
    @ViewBuilder
    func cassetteAccentGlassButton(disabled: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(.cassetteAccent).disabled(disabled)
        } else {
            self.buttonStyle(.borderedProminent).tint(.cassetteAccent).disabled(disabled)
        }
    }

    /// Soft panel for cards / accessory chrome. Cheap path uses material, not Liquid Glass.
    @ViewBuilder
    func cassetteGlassPanel(cornerRadius: CGFloat = 16) -> some View {
        if !CassettePerformance.preferCheapChrome,
           #available(macOS 26.0, iOS 26.0, *) {
            self.glassEffect(Glass.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }

    /// Over-cover HERO round button: transparent tap area + soft shadow for glyph legibility.
    func cassetteHeroButton(size: CGFloat = 44) -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }

    /// Circular control without Liquid Glass — soft fill for over-cover chrome (player star / more).
    func cassettePlainCircleButton(size: CGFloat = 44, fill: Color) -> some View {
        self
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(fill)
            }
    }

    /// Capsule control without Liquid Glass (queue shuffle / repeat / auto-extend pills).
    func cassettePlainCapsule(fill: Color) -> some View {
        self
            .contentShape(Capsule())
            .background {
                Capsule()
                    .fill(fill)
            }
    }
}
