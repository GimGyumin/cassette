// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Reusable mesh gradient background derived from a 3-color palette.
/// Falls back to LinearGradient on macOS 14 where MeshGradient is unavailable.
/// Animation is paused off-screen, in the background, in Low Power Mode, under Reduce Motion,
/// and while the device reports thermal pressure (see `PerformanceGovernor`).
struct MeshGradientBackground: View {
    /// 3 colors from WrappedYearPalette.
    let palette: [Color]
    /// When true, subtly animates mesh control points (8s period, ±0.04 amplitude).
    let animated: Bool

    @Environment(\.scenePhase) private var scenePhase
    /// Observed so a budget change restarts/stops the animation immediately instead of waiting for
    /// the next unrelated state change.
    @State private var governor = PerformanceGovernor.shared
    @State private var animationPhase: CGFloat = 0
    @State private var isVisible = false

    private var shouldAnimate: Bool {
        animated && isVisible && scenePhase == .active && governor.budget.allowsDecorativeMotion
    }

    var body: some View {
        gradient
            .onAppear {
                isVisible = true
                syncAnimation()
            }
            .onDisappear {
                isVisible = false
                syncAnimation()
            }
            .onChange(of: scenePhase) { _, _ in syncAnimation() }
            .onChange(of: governor.budget) { _, _ in syncAnimation() }
            .onChange(of: animated) { _, _ in syncAnimation() }
    }

    private func syncAnimation() {
        guard shouldAnimate else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { animationPhase = 0 }
            return
        }
        withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
            animationPhase = 1
        }
    }

    @ViewBuilder
    private var gradient: some View {
        if #available(iOS 18, macOS 15, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: currentPoints,
                colors: distributedColors
            )
        } else {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var currentPoints: [SIMD2<Float>] {
        let p = Float(shouldAnimate ? animationPhase : 0)
        return [
            [0.0, 0.0], [0.5 + 0.04 * p, 0.0],                        [1.0, 0.0],
            [0.0, 0.5 + 0.03 * p], [0.5 - 0.04 * p, 0.5 + 0.04 * p], [1.0, 0.5 - 0.03 * p],
            [0.0, 1.0], [0.5 + 0.03 * p, 1.0],                        [1.0, 1.0]
        ]
    }

    // Diagonal sweep: c0 top-left → c1 center → c2 bottom-right
    private var distributedColors: [Color] {
        guard palette.count >= 3 else {
            return Array(repeating: palette.first ?? .clear, count: 9)
        }
        let c0 = palette[0], c1 = palette[1], c2 = palette[2]
        return [c0, c0, c1,
                c0, c1, c1,
                c1, c2, c2]
    }
}
