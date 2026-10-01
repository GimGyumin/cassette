// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Single-line title that auto-scrolls horizontally when the text overflows its container
/// (Apple Music–style marquee). Short titles stay static and leading-aligned.
///
/// Important: measurement uses an overlay/`fixedSize` that must NOT participate in layout —
/// otherwise a long title expands the parent (full player HStack) past the screen width and
/// clips title, scrubber, and controls on both edges.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    /// Pause before / after a scroll cycle.
    var pauseDuration: Double = 1.4
    /// Points per second while scrolling.
    var speed: Double = 28

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Observed so the scroll loop starts/stops with the performance budget (Reduce Motion, Low
    /// Power Mode, thermal pressure, background) — a marquee is pure decoration and can be the
    /// only animation running in a long list.
    @State private var governor = PerformanceGovernor.shared

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var needsMarquee: Bool {
        overflow > 4 && containerWidth > 0 && governor.budget.allowsDecorativeMotion
    }

    var body: some View {
        // Invisible single-line glyph sets the correct height for `font` without widening layout.
        Text("\u{00A0}")
            .font(font)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: MarqueeTextWidthKey.self, value: geo.size.width)
                        }
                    )
                    .offset(x: needsMarquee ? offset : 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: MarqueeContainerWidthKey.self, value: geo.size.width)
                }
            )
            // Debounce preference → @State: during player side-panel width animations, raw
            // preference churn can invalidate the tree every frame and freeze the UI (iPad).
            .onPreferenceChange(MarqueeTextWidthKey.self) { newValue in
                if abs(newValue - textWidth) > 2 { textWidth = newValue }
            }
            .onPreferenceChange(MarqueeContainerWidthKey.self) { newValue in
                if abs(newValue - containerWidth) > 2 { containerWidth = newValue }
            }
            .task(id: marqueeTaskID) {
                offset = 0
                guard needsMarquee, scenePhase == .active else { return }
                while !Task.isCancelled {
                    offset = 0
                    try? await Task.sleep(for: .seconds(pauseDuration))
                    guard !Task.isCancelled, needsMarquee else { continue }
                    let distance = overflow + 28
                    let duration = max(0.8, distance / speed)
                    withAnimation(.linear(duration: duration)) {
                        offset = -distance
                    }
                    try? await Task.sleep(for: .seconds(duration + pauseDuration))
                }
            }
            .accessibilityLabel(text)
    }

    /// Restart only when the title / motion policy / foreground state changes — not on every width tick.
    private var marqueeTaskID: String {
        "\(text)|\(governor.budget.allowsDecorativeMotion)|\(scenePhase == .active)"
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
