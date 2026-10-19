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
    @State private var isVisible = false

    private var shouldAnimate: Bool {
        animated && isVisible && scenePhase == .active && governor.budget.allowsDecorativeMotion
    }

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: governor.budget.meshFrameInterval)) { context in
                    let phase = Float((1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 8)) / 2)
                    gradient(phase: phase)
                }
            } else {
                gradient(phase: 0)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    @ViewBuilder
    private func gradient(phase: Float) -> some View {
        if #available(iOS 18, macOS 15, *) {
            MeshGradient(width: 3, height: 3, points: points(phase: phase), colors: distributedColors)
        } else {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func points(phase p: Float) -> [SIMD2<Float>] {
        [
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
