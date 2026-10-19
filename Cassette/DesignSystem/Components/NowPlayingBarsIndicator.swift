// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Reads coalesced PCM energy only while visible. No synthetic repeating waveform.
struct NowPlayingBarsIndicator: View {
    let isPlaying: Bool

    @Environment(\.cassettePlayingAccent) private var playingAccent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var governor = PerformanceGovernor.shared
    @State private var isVisible = false
    @State private var isListening = false
    @State private var meter = PlaybackBeatMeter.shared

    private var wantsMotion: Bool {
        isVisible && isPlaying && scenePhase == .active && !reduceMotion && governor.budget.allowsBeatVisuals
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(playingAccent)
                    .frame(width: 2.5, height: wantsMotion ? 2 + 12 * meter.bands[index] : 3)
            }
        }
        .frame(width: 16, height: 14, alignment: .bottom)
        .animation(wantsMotion ? .linear(duration: CassettePerformance.beatPublishInterval) : nil, value: meter.bands)
        .accessibilityLabel(isPlaying ? "Now Playing" : "Paused")
        .onAppear { isVisible = true; updateListening() }
        .onDisappear { isVisible = false; updateListening() }
        .onChange(of: wantsMotion) { _, _ in updateListening() }
    }

    private func updateListening() {
        guard wantsMotion != isListening else { return }
        isListening = wantsMotion
        if isListening { meter.retainUIListening() } else { meter.releaseUIListening() }
    }
}
