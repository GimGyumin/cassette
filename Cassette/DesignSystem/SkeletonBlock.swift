// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A subtle pulsing rectangle used as a loading placeholder.
/// Opacity oscillates discretely (0.05 ↔ 0.10) with a slow ease-in-out, no shimmer sweep.
struct SkeletonBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @State private var isPulsing = false
    @State private var isVisible = false
    @State private var governor = PerformanceGovernor.shared
    @Environment(\.scenePhase) private var scenePhase

    private var shouldAnimate: Bool {
        isVisible && scenePhase == .active && governor.budget.allowsDecorativeMotion
    }

    init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 6) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(isPulsing ? 0.10 : 0.05))
            .frame(width: width, height: height)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; syncAnimation() }
            .onChange(of: shouldAnimate) { _, _ in syncAnimation() }
    }

    private func syncAnimation() {
        withAnimation(shouldAnimate ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil) {
            isPulsing = shouldAnimate
        }
    }
}
