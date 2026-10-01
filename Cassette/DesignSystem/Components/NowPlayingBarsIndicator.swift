// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Apple Music–style equalizer that replaces a track number while that song is current.
/// Bar heights come from live `PlaybackBeatMeter` audio energy (not a canned loop).
struct NowPlayingBarsIndicator: View {
    let isPlaying: Bool

    @Environment(\.cassettePlayingAccent) private var playingAccent
    @Environment(\.scenePhase) private var scenePhase
    /// Observed so the equalizer starts/stops with the performance budget (background, Low Power
    /// Mode, Reduce Motion, thermal pressure) instead of keeping a mixer tap alive.
    @State private var governor = PerformanceGovernor.shared
    @State private var beatMeter = PlaybackBeatMeter.shared
    @State private var isRetainingMeter = false

    private let barCount = PlaybackBeatMeter.bandCount
    private let minBar: CGFloat = 3
    private let maxBar: CGFloat = 14

    private var wantsLiveAudio: Bool {
        isPlaying && scenePhase == .active && governor.budget.allowsBeatVisuals
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(playingAccent)
                    .frame(width: 2.5, height: height(for: i))
            }
        }
        .frame(width: 16, height: maxBar, alignment: .bottom)
        .accessibilityLabel(isPlaying ? "Now Playing" : "Paused")
        .onAppear { syncMeterListening() }
        .onDisappear { releaseMeterIfNeeded() }
        .onChange(of: isPlaying) { _, _ in syncMeterListening() }
        .onChange(of: scenePhase) { _, _ in syncMeterListening() }
        .onChange(of: governor.budget) { _, _ in syncMeterListening() }
        .animation(wantsLiveAudio ? .easeOut(duration: 0.08) : nil, value: wantsLiveAudio ? beatMeter.bands : [])
    }

    private func height(for index: Int) -> CGFloat {
        guard wantsLiveAudio else {
            // Paused / reduced motion: quiet static equalizer silhouette.
            let paused: [CGFloat] = [0.22, 0.38, 0.28, 0.18]
            return minBar + (maxBar - minBar) * paused[index % paused.count]
        }
        let energy = index < beatMeter.bands.count ? beatMeter.bands[index] : 0.12
        // Slight per-bar shaping so the silhouette reads like a classic EQ.
        let shaped = energy * (index == 1 || index == 2 ? 1.05 : 0.92)
        return minBar + (maxBar - minBar) * min(1, max(0.08, shaped))
    }

    private func syncMeterListening() {
        if wantsLiveAudio {
            guard !isRetainingMeter else { return }
            beatMeter.retainUIListening()
            isRetainingMeter = true
        } else {
            releaseMeterIfNeeded()
        }
    }

    private func releaseMeterIfNeeded() {
        guard isRetainingMeter else { return }
        beatMeter.releaseUIListening()
        isRetainingMeter = false
    }
}
