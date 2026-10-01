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

// MARK: - Scrubber

struct ScrubberView: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    let contentColor: Color
    let secondaryContentColor: Color
    var isExpensiveNetwork: Bool = false

    @State private var isDragging = false
    @State private var isSeeking = false
    @State private var displayPosition: TimeInterval = 0
    @State private var seekGeneration = 0

    private var effectiveDuration: TimeInterval {
        playerState.duration > 0 ? playerState.duration : (playerState.currentTrack?.duration ?? 1)
    }

    private var playbackQuality: AudioQualityKind? {
        guard !playerState.isLiveStream, let track = playerState.currentTrack else { return nil }
        return AudioQualityClassifier.displayablePlaybackQuality(
            for: track,
            isExpensive: isExpensiveNetwork,
            isTranscoding: playerState.isDeliveringTranscodedAudio
        )
    }

    private var positionBinding: Binding<TimeInterval> {
        Binding(
            get: { (isDragging || isSeeking) ? displayPosition : playerState.position },
            set: { newValue in displayPosition = newValue }
        )
    }

    var body: some View {
        VStack(spacing: CassetteSpacing.xs) {
            ProgressSlider(
                value: positionBinding,
                total: effectiveDuration,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        seekGeneration &+= 1
                        let generation = seekGeneration
                        isSeeking = true
                        let target = max(0, min(displayPosition, effectiveDuration))
                        Task {
                            await playerService?.seek(to: target)
                            guard generation == seekGeneration else { return }
                            isSeeking = false
                        }
                    }
                },
                trackColor: contentColor.opacity(0.22),
                fillColor: contentColor.opacity(0.95),
                trackHeight: 7,
                isInteracting: isDragging || isSeeking
            )

            ScrubberTimeLabels(
                playerState: playerState,
                effectiveDuration: effectiveDuration,
                overridePosition: (isDragging || isSeeking) ? displayPosition : nil,
                color: secondaryContentColor,
                quality: playbackQuality
            )
        }
    }
}

private struct ScrubberTimeLabels: View {
    let playerState: PlayerState
    let effectiveDuration: TimeInterval
    let overridePosition: TimeInterval?
    let color: Color
    var quality: AudioQualityKind? = nil

    private var hasPlayableDuration: Bool {
        playerState.currentTrack != nil && effectiveDuration > 0 && !playerState.isLiveStream
    }

    var body: some View {
        let shown = overridePosition ?? playerState.position
        HStack {
            Text(hasPlayableDuration
                 ? Duration.seconds(shown).formatted(.time(pattern: .minuteSecond))
                 : "--:--")
                .font(.cassetteCaption)
                .foregroundStyle(color)
                .monospacedDigit()
            Spacer(minLength: 8)
            if let quality {
                AudioQualityLabelView(quality: quality, foreground: color, usesGlass: false)
                    .offset(y: -3)
            }
            Spacer(minLength: 8)
            Text(hasPlayableDuration
                 ? Duration.seconds(max(effectiveDuration - shown, 0)).formatted(.time(pattern: .minuteSecond))
                 : "--:--")
                .font(.cassetteCaption)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

struct ProgressSlider: View {
    @Binding var value: TimeInterval
    let total: TimeInterval
    let onEditingChanged: (Bool) -> Void
    var trackColor: Color = Color.white.opacity(0.2)
    var fillColor: Color = Color.white.opacity(0.95)
    var height: CGFloat = 32
    var trackHeight: CGFloat = 5
    var activeTrackHeight: CGFloat = 12
    var dragMinimumDistance: CGFloat = 0
    var isInteracting: Bool = false
    /// Volume-style behaviour: pressing only shows the active (thicker) bar — the value never jumps
    /// to the touch point. It moves *relative* to the value the press started from, so a tap (or a
    /// finger wobble while holding) cannot slam the volume. Progress scrubbers keep the default
    /// (touch = seek to that position).
    var ignoresTapForValueChange: Bool = false

    /// Finger travel (points) required before a press-only control starts following the finger.
    private static let valueChangeThreshold: CGFloat = 2

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?
    /// Value when the current press began — the anchor for relative (volume-style) dragging.
    @State private var dragAnchor: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let trackW = geo.size.width
            let barHeight = isDragging ? activeTrackHeight : trackHeight

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(fillColor)
                    .frame(width: progressWidth(in: trackW))
                    .animation(nil, value: value)
            }
            .frame(height: barHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDragging)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: dragMinimumDistance)
                    .onChanged { gesture in
                        guard trackW > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            dragAnchor = value
                            onEditingChanged(true)
                            HapticFeedback.light.trigger()
                        }
                        let next: TimeInterval
                        if ignoresTapForValueChange {
                            // Relative: travel, not position, decides the new value.
                            guard let anchor = dragAnchor,
                                  abs(gesture.translation.width) >= Self.valueChangeThreshold else { return }
                            next = anchor + total * Double(gesture.translation.width / trackW)
                        } else {
                            let fraction = max(0, min(1, gesture.location.x / trackW))
                            next = total * Double(fraction)
                        }
                        dragValue = max(0, min(total, next))
                        value = dragValue ?? value
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragValue = nil
                        dragAnchor = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: height)
        .accessibilityLabel(String(localized: "Playback position", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue(Duration.seconds(value).formatted(.time(pattern: .minuteSecond)))
        .accessibilityAdjustableAction { direction in
            let step = total * 0.05
            switch direction {
            case .increment:
                value = min(value + step, total)
                onEditingChanged(false)
            case .decrement:
                value = max(value - step, 0)
                onEditingChanged(false)
            @unknown default: break
            }
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let displayedValue = dragValue ?? value
        return min(totalWidth, max(0, (CGFloat(displayedValue) / CGFloat(total)) * totalWidth))
    }
}

// MARK: - Playback controls

struct PlaybackControlsView: View {
    let playerState: PlayerState
    let playerService: (any PlayerServiceProtocol)?
    var isPlaybackAvailable: Bool = true
    let contentColor: Color
    let secondaryContentColor: Color
    var showsShuffleRepeat: Bool = false

    var body: some View {
        HStack(spacing: showsShuffleRepeat ? CassetteSpacing.xl : CassetteSpacing.xxxxl) {
            if showsShuffleRepeat, !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await playerService?.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(playerState.isShuffled ? Color.cassetteAccent : secondaryContentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel(String(localized: "Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { try? await playerService?.skipToPrevious() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 36, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                        .frame(width: 64, height: 64)
                }
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel("Skip to previous")
            }

            // A stream that is still opening shows the plain play glyph instead of a spinner: the
            // transport keeps one visual language, and a pause/stop glyph before any audio exists
            // would claim playback that is not happening. The control stays inert — no audio exists
            // yet, so a tap must not restart the preparation that is already in flight.
            if playerState.playbackState.controlAppearance == .loading {
                Image(systemName: "play.fill")
                    .font(.system(size: 44, weight: .semibold, design: .default))
                    .foregroundStyle(isPlaybackAvailable ? Color.white : Color.white.opacity(0.4))
                    .frame(minWidth: showsShuffleRepeat ? 72 : 88, minHeight: showsShuffleRepeat ? 72 : 88)
                    .accessibilityLabel(String(localized: "Loading", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            } else {
                Button {
                    HapticFeedback.medium.trigger()
                    Task {
                        if playerState.playbackState == .playing {
                            await playerService?.pause()
                        } else {
                            await playerService?.resume()
                        }
                    }
                } label: {
                    Image(systemName: playerState.playbackState.controlAppearance == .pause ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .semibold, design: .default))
                        .foregroundStyle(isPlaybackAvailable ? Color.white : Color.white.opacity(0.4))
                        .frame(minWidth: showsShuffleRepeat ? 72 : 88, minHeight: showsShuffleRepeat ? 72 : 88)
                        .contentShape(Rectangle())
                }
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel(playerState.playbackState.controlAppearance == .pause ? "Pause" : "Play")
            }

            if !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { try? await playerService?.skipToNext() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 36, weight: .semibold, design: .default))
                        .foregroundStyle(Color.white)
                        .frame(width: 64, height: 64)
                }
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel("Skip to next")
            }

            if showsShuffleRepeat, !playerState.isLiveStream {
                Button {
                    HapticFeedback.light.trigger()
                    Task { await playerService?.setRepeatMode(playerState.repeatMode.next) }
                } label: {
                    Image(systemName: playerState.repeatMode.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(playerState.repeatMode != .off ? Color.cassetteAccent : secondaryContentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!isPlaybackAvailable)
                .accessibilityLabel(String(localized: "Repeat", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
    }
}
