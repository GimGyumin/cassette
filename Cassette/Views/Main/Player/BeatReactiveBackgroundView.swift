// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

struct BeatReactiveBackgroundView: View {
    let dominant: Color
    var top: Color = .black
    var mid: Color = .black
    var bottom: Color = .black
    let isPlaying: Bool
    let coverImage: PlatformImage?
    var freezeBeat: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    /// Observed so the wash starts/stops with the performance budget.
    @State private var governor = PerformanceGovernor.shared
    @State private var beatMeter = PlaybackBeatMeter.shared
    @State private var isRetainingMeter = false

    private var wantsLiveAudio: Bool {
        isPlaying && !freezeBeat && scenePhase == .active && governor.budget.allowsBeatVisuals
    }

    var body: some View {
        let energy = wantsLiveAudio
            ? beatMeter.level * 0.55 + beatMeter.beatPulse * 0.35
            : 0

        let washTop = top == .black ? dominant : top
        let washMid = mid == .black ? dominant : mid
        let washBottom = bottom == .black ? dominant : bottom
        ZStack {
            Color.black

            if let coverImage {
                Image(platformImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.48)
                    .saturation(0.68)
                    .contrast(0.92)
                    .brightness(-0.10)
                    .blur(radius: 74, opaque: true)
                    .opacity(0.74)
                    .overlay(Color.black.opacity(0.40))
            }

            LinearGradient(
                colors: [
                    washTop.opacity(coverImage == nil ? 1.0 : 0.38),
                    washMid.opacity(coverImage == nil ? 1.0 : 0.46),
                    washBottom.opacity(coverImage == nil ? 1.0 : 0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.04),
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.27)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if wantsLiveAudio {
                washTop
                    .opacity(Double(energy) * 0.10)
                    .blendMode(.plusLighter)
                    .animation(.easeOut(duration: 0.14), value: beatMeter.level)

                RadialGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.16 + Double(energy) * 0.08)
                    ],
                    center: .center,
                    startRadius: 40,
                    endRadius: 520
                )
                .animation(.easeOut(duration: 0.14), value: beatMeter.level)
            } else {
                RadialGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.16)
                    ],
                    center: .center,
                    startRadius: 40,
                    endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: wantsLiveAudio) {
            await syncMeterListening()
        }
        .onDisappear { releaseMeterIfNeeded() }
    }

    private func syncMeterListening() async {
        if !wantsLiveAudio {
            releaseMeterIfNeeded()
            return
        }
        // Sleep inside SwiftUI's lifecycle task, not an unstructured child Task.
        // Leaving the screen cancels the pending retain before it can leak a listener.
        do { try await Task.sleep(for: .milliseconds(350)) }
        catch { return }
        guard !Task.isCancelled, wantsLiveAudio, !isRetainingMeter else { return }
        beatMeter.retainUIListening()
        isRetainingMeter = true
    }

    private func releaseMeterIfNeeded() {
        guard isRetainingMeter else { return }
        beatMeter.releaseUIListening()
        isRetainingMeter = false
    }
}
