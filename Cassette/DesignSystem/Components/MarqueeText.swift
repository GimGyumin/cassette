// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Allows a parent title-swipe container to freeze the marquee while the user
/// is dragging. The marquee owns its own offset; the gesture only controls this
/// flag, so the two horizontal motions never share state.
private struct MarqueePausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var marqueePaused: Bool {
        get { self[MarqueePausedKey.self] }
        set { self[MarqueePausedKey.self] = newValue }
    }
}

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
    @Environment(\.marqueePaused) private var isPaused
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
            // Mask the container, not the moving text: the gradient must stay
            // anchored to the visible edges while the title scrolls underneath.
            .mask { edgeMask }
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
                guard needsMarquee, scenePhase == .active, !isPaused else {
                    resetOffset()
                    return
                }
                // Resuming after a drag/transition: glide back to the leading edge
                // instead of snapping. A new track starts at 0 and skips this.
                if offset != 0 {
                    withAnimation(.easeOut(duration: 0.20)) { offset = 0 }
                    try? await Task.sleep(for: .seconds(0.20))
                    guard !Task.isCancelled else { return }
                }
                while !Task.isCancelled {
                    offset = 0
                    try? await Task.sleep(for: .seconds(pauseDuration))
                    guard !Task.isCancelled, needsMarquee, !isPaused else { return }

                    let distance = overflow + 28
                    let duration = max(0.8, distance / speed)
                    withAnimation(.linear(duration: duration)) { offset = -distance }
                    try? await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled, needsMarquee, !isPaused else { return }

                    // Hold at the end so the tail is readable, then return smoothly.
                    try? await Task.sleep(for: .seconds(pauseDuration))
                    guard !Task.isCancelled, needsMarquee, !isPaused else { return }
                    withAnimation(.easeInOut(duration: 0.32)) { offset = 0 }
                    try? await Task.sleep(for: .seconds(0.32))
                }
            }
            .onDisappear { resetOffset() }
            .accessibilityLabel(text)
    }

    private func resetOffset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
    }

    @ViewBuilder
    private var edgeMask: some View {
        if needsMarquee {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.white
        }
    }

    /// Restart only when the title, measured layout, motion policy, foreground
    /// state or pause state changes — not on every width tick.
    private var marqueeTaskID: String {
        "\(text)|\(Int(textWidth.rounded()))|\(Int(containerWidth.rounded()))|\(governor.budget.allowsDecorativeMotion)|\(scenePhase == .active)|\(isPaused)"
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
