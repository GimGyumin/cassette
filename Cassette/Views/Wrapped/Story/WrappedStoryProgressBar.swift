// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Only this small leaf animates. The slide, artwork and glass controls don't read
/// frame-by-frame progress, and no timer runs during a hold or in the background.
struct WrappedStoryTimedProgressBar: View {
    let totalSlides: Int
    let currentIndex: Int
    let timing: StorySlideTiming
    @State private var displayedProgress = 0.0

    var body: some View {
        WrappedStoryProgressBar(totalSlides: totalSlides, currentIndex: currentIndex,
                                progress: displayedProgress)
            .task(id: timing) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { displayedProgress = timing.progress }
                guard timing.startedAt != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: timing.remaining)) { displayedProgress = 1 }
            }
    }
}

/// Segmented progress bar shown at the top of the story player.
/// Segments before `currentIndex` are fully filled; the current segment
/// fills proportionally to `progress` (0…1); subsequent segments are empty.
struct WrappedStoryProgressBar: View {
    let totalSlides: Int
    let currentIndex: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<totalSlides, id: \.self) { index in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * segmentFill(for: index))
                    }
                }
                .frame(height: 2.5)
            }
        }
    }

    private func segmentFill(for index: Int) -> Double {
        if index < currentIndex { return 1.0 }
        if index == currentIndex { return max(0, min(1, progress)) }
        return 0.0
    }
}
