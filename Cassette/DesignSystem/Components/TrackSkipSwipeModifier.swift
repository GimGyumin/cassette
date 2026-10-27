// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

#if os(iOS)
import UIKit

private struct TrackSkipSwipeModifier: ViewModifier {
    @Environment(\.appContainer) private var container
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimatingSwipe = false

    let playerState: PlayerState

    private let swipeThreshold: CGFloat = 80
    private let velocityThreshold: CGFloat = 200

    func body(content: Content) -> some View {
        content
            .offset(x: dragOffset)
            .opacity(1.0 - min(abs(dragOffset) / 200, 0.4))
            .gesture(swipeGesture)
            .onChange(of: playerState.currentTrack?.id) { _, _ in dragOffset = 0 }
    }

    private var swipeGesture: PlayerHorizontalPanGesture {
        PlayerHorizontalPanGesture { offset, velocity, ended, cancelled in
            guard !isAnimatingSwipe, !playerState.isLiveStream else { return }
            if cancelled { bounceBack(); return }
            if !ended { dragOffset = offset; return }
            let next = offset < -swipeThreshold || velocity < -velocityThreshold
            let previous = offset > swipeThreshold || velocity > velocityThreshold
            if next || previous { commitSwipe(goNext: next) }
            else { bounceBack() }
        }
    }

    private func commitSwipe(goNext: Bool) {
        isAnimatingSwipe = true
        HapticFeedback.medium.trigger()
        withAnimation(.easeIn(duration: 0.18)) { dragOffset = goNext ? -300 : 300 }
        Task {
            if goNext {
                try? await container?.playerService.skipToNext()
            } else {
                try? await container?.playerService.skipToPrevious()
            }
            await MainActor.run {
                dragOffset = goNext ? 300 : -300
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragOffset = 0 }
                isAnimatingSwipe = false
            }
        }
    }

    private func bounceBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragOffset = 0 }
    }
}
/// Reject vertical pans before recognition so UIKit's interactive zoom dismissal
/// owns them from the first frame. Filtering in onChanged is already too late.
struct PlayerHorizontalPanGesture: UIGestureRecognizerRepresentable {
    var action: (CGFloat, CGFloat, Bool, Bool) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        action(recognizer.translation(in: recognizer.view).x,
               recognizer.velocity(in: recognizer.view).x, recognizer.state == .ended,
               recognizer.state == .cancelled || recognizer.state == .failed)
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return PlayerArtworkGesturePolicy.isHorizontal(velocity: CGSize(width: velocity.x, height: velocity.y))
        }
    }
}

#endif

extension View {
    func trackSkipSwipe(playerState: PlayerState) -> some View {
        #if os(iOS)
        modifier(TrackSkipSwipeModifier(playerState: playerState))
        #else
        self
        #endif
    }
}

nonisolated enum PlayerArtworkGesturePolicy {
    static func isHorizontal(velocity: CGSize) -> Bool {
        abs(velocity.width) > abs(velocity.height) * 1.2
    }
}
