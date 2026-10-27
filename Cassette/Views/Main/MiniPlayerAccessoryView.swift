// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

struct MiniPlayerAccessoryView: View {
    @Binding var showingFullPlayer: Bool
    /// Opens the full player already on the lyrics panel (iPad floating bar).
    var onOpenLyrics: (() -> Void)? = nil
    /// Opens the full player already on the queue panel (iPad floating bar).
    var onOpenQueue: (() -> Void)? = nil
    var usesSystemAccessory = false
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Semantic colors follow the system accessory's own appearance and contrast settings.
    private var typoColor: Color { .primary }
    private var typoSecondaryColor: Color { .secondary }

    @ViewBuilder
    private var miniPlayerSurface: some View {
        if !usesSystemAccessory {
            Capsule().fill(.regularMaterial).allowsHitTesting(false)
        }
    }

    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }

    /// Apple Music–style wide floating capsule (iPad regular / large width).
    private var usesPadFloatingBar: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    var body: some View {
        if let playerState = container?.playerState {
            Group {
                if #available(macOS 26.0, iOS 26.0, *), usesSystemAccessory {
                    MiniPlayerPlacementReader { isInline in
                        playerContent(playerState, isInline: isInline)
                    }
                } else {
                    playerContent(playerState, isInline: false)
                }
            }
        }
    }

    @ViewBuilder
    private func playerContent(_ playerState: PlayerState, isInline: Bool) -> some View {
        let isLiveStream = playerState.isLiveStream
        let coverArtId = isLiveStream
            ? (playerState.currentRadio?.coverArt ?? "")
            : (container?.playbackCoverId(for: playerState.currentTrack)
                ?? playerState.currentTrack?.effectiveCoverArtId ?? "")
        let title = hasTrack
            ? (isLiveStream ? (playerState.currentRadio?.name ?? "") : (playerState.currentTrack?.title ?? ""))
            : String(localized: "Not Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        let artist: String? = hasTrack
            ? (isLiveStream ? String(localized: "Live Radio", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : playerState.currentTrack?.artist)
            : nil
        let playbackAppearance = playerState.playbackState.controlAppearance
        let isAvailable = hasTrack && playerState.isPlaybackAvailable

        Group {
            if usesPadFloatingBar && !isInline {
                padFloatingBar(
                    playerState: playerState,
                    coverArtId: coverArtId,
                    title: title,
                    artist: artist,
                    playbackAppearance: playbackAppearance,
                    isAvailable: isAvailable,
                    isLiveStream: isLiveStream
                )
            } else if isInline {
                inlineBar(
                    playerState: playerState,
                    coverArtId: coverArtId,
                    title: title,
                    artist: artist,
                    playbackAppearance: playbackAppearance,
                    isAvailable: isAvailable,
                    isLiveStream: isLiveStream
                )
            } else {
                expandedBar(
                    playerState: playerState,
                    coverArtId: coverArtId,
                    title: title,
                    artist: artist,
                    playbackAppearance: playbackAppearance,
                    isAvailable: isAvailable,
                    isLiveStream: isLiveStream
                )
            }
        }
        .modifier(MiniPlayerTapOpenModifier(
            enabled: (!usesPadFloatingBar || isInline) && hasTrack,
            open: { showingFullPlayer = true }
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(miniPlayerAccessibilityLabel(title: title, artist: artist))
        .accessibilityHint(hasTrack ? String(localized: "Opens full player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : "")
        .accessibilityAddTraits(hasTrack ? .isButton : [])
        .accessibilityAction(named: String(localized: "Open player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
            guard hasTrack else { return }
            showingFullPlayer = true
        }
    }

    private func miniPlayerAccessibilityLabel(title: String, artist: String?) -> String {
        if let artist, hasTrack {
            return "\(String(localized: "Now Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)), \(title), \(artist)"
        }
        return title
    }

    // MARK: - iPad floating capsule (Apple Music–style)

    private func padFloatingBar(
        playerState: PlayerState,
        coverArtId: String,
        title: String,
        artist: String?,
        playbackAppearance: PlaybackControlAppearance,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        HStack(spacing: 0) {
            padTransportControls(playerState: playerState, playbackAppearance: playbackAppearance, isAvailable: isAvailable, isLiveStream: isLiveStream)
                .frame(minWidth: 200, alignment: .leading)

            padNowPlayingBlock(
                playerState: playerState,
                coverArtId: coverArtId,
                title: title,
                artist: artist,
                isAvailable: isAvailable,
                isLiveStream: isLiveStream
            )
            .frame(maxWidth: .infinity)

            padSecondaryActions(isLiveStream: isLiveStream)
                .frame(minWidth: 140, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .frame(maxWidth: 920)
        .background { if !usesSystemAccessory { padCapsuleBackground } }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var padCapsuleBackground: some View {
        #if os(iOS)
        if #available(iOS 26.0, *), !CassettePerformance.preferCheapChrome {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
        }
        #else
        Capsule()
            .fill(.ultraThinMaterial)
        #endif
    }

    private func padTransportControls(
        playerState: PlayerState,
        playbackAppearance: PlaybackControlAppearance,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        HStack(spacing: 18) {
            Button {
                HapticFeedback.light.trigger()
                Task { await container?.playerService.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(playerState.isShuffled ? Color.cassetteAccent : typoSecondaryColor)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!hasTrack || isLiveStream || !isAvailable)
            .accessibilityLabel(String(localized: "Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue(playerState.isShuffled ? String(localized: "On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                HapticFeedback.light.trigger()
                Task { try? await container?.playerService.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(typoColor.opacity(isAvailable ? 1 : 0.35))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!isAvailable || isLiveStream)
            .accessibilityLabel(String(localized: "Skip to previous", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                HapticFeedback.medium.trigger()
                Task { await container?.playerService.togglePlayPause() }
            } label: {
                Image(systemName: playbackAppearance.systemImage)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(typoColor.opacity(hasTrack ? 1 : 0.35))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(!hasTrack)
            .accessibilityLabel(playbackAppearance == .play ? String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Pause", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                HapticFeedback.light.trigger()
                Task { try? await container?.playerService.skipToNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(typoColor.opacity(isAvailable ? 1 : 0.35))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!isAvailable || isLiveStream)
            .accessibilityLabel(String(localized: "Skip to next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                HapticFeedback.light.trigger()
                Task { await container?.playerService.setRepeatMode(playerState.repeatMode.next) }
            } label: {
                Image(systemName: playerState.repeatMode.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(playerState.repeatMode != .off ? Color.cassetteAccent : typoSecondaryColor)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!hasTrack || isLiveStream || !isAvailable)
            .accessibilityLabel(String(localized: "Repeat", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private func padNowPlayingBlock(
        playerState: PlayerState,
        coverArtId: String,
        title: String,
        artist: String?,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        HStack(spacing: 12) {
            artwork(coverArtId: coverArtId, size: 44, isAvailable: isAvailable || !hasTrack)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: title,
                    font: .subheadline.weight(.semibold),
                    color: typoColor
                )
                if isLiveStream, hasTrack {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                } else if let artist, hasTrack {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(typoSecondaryColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(
                TrackTextSwipeTransition(
                    playerState: playerState,
                    enabled: isAvailable && !isLiveStream && hasTrack,
                    onNext: {
                        Task { try? await container?.playerService.skipToNext() }
                    },
                    onPrevious: {
                        Task { try? await container?.playerService.skipToPrevious() }
                    },
                    commitDistance: 44,
                    predictedDistance: 100,
                    maxOffset: 90,
                    resistance: 0.6
                )
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasTrack else { return }
            showingFullPlayer = true
        }
    }

    private func padSecondaryActions(isLiveStream: Bool) -> some View {
        HStack(spacing: 16) {
            Menu {
                Button {
                    showingFullPlayer = true
                } label: {
                    Label(String(localized: "Open Player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "play.square.fill")
                }
                .disabled(!hasTrack)

                    if let song = container?.playerState.currentTrack {
                    Divider()
                    Button {
                        Task {
                            guard let favorites = container?.favoritesService else { return }
                            let isFav = favorites.isFavorite(itemType: .song, itemId: song.id)
                            if isFav {
                                try? await favorites.unstar(itemType: .song, itemId: song.id)
                            } else {
                                try? await favorites.star(itemType: .song, itemId: song.id)
                            }
                        }
                    } label: {
                        let isFav = container?.favoritesService.isFavorite(itemType: .song, itemId: song.id) == true
                        Label(
                            isFav ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            systemImage: isFav ? "star.slash" : "star"
                        )
                    }
                    .disabled(container?.serverState.isOnline != true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(typoColor.opacity(hasTrack ? 0.9 : 0.35))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!hasTrack)
            .accessibilityLabel(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                guard hasTrack else { return }
                if let onOpenLyrics {
                    onOpenLyrics()
                } else {
                    showingFullPlayer = true
                }
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(typoColor.opacity(hasTrack && !isLiveStream ? 0.9 : 0.35))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!hasTrack || isLiveStream)
            .accessibilityLabel(String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                guard hasTrack else { return }
                if let onOpenQueue {
                    onOpenQueue()
                } else {
                    showingFullPlayer = true
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(typoColor.opacity(hasTrack && !isLiveStream ? 0.9 : 0.35))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!hasTrack || isLiveStream)
            .accessibilityLabel(String(localized: "Queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    // MARK: - iPhone bars

    /// Compact pill content for the minimized tab bar: art · title/artist · play.
    private func inlineBar(
        playerState: PlayerState,
        coverArtId: String,
        title: String,
        artist: String?,
        playbackAppearance: PlaybackControlAppearance,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        HStack(spacing: 10) {
            artwork(coverArtId: coverArtId, size: 28, isAvailable: isAvailable || !hasTrack)

            miniPlayerTitle(
                playerState: playerState,
                title: title,
                subtitle: artist,
                compact: true,
                enabled: isAvailable && !isLiveStream && hasTrack
            )

            playPauseButton(playbackAppearance: playbackAppearance, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { miniPlayerSurface }
    }

    /// Shared Apple Music–style title block for both mini-player sizes. The
    /// title marquee and the swipe/transition container own separate state.
    private func miniPlayerTitle(
        playerState: PlayerState,
        title: String,
        subtitle: String?,
        compact: Bool,
        enabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            MarqueeText(
                text: title,
                font: compact ? .subheadline.weight(.semibold) : .cassetteCellTitle,
                color: typoColor
            )

            if let subtitle, hasTrack {
                Text(subtitle)
                    .font(compact ? .caption2 : .cassetteCaption)
                    .foregroundStyle(typoSecondaryColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            TrackTextSwipeTransition(
                playerState: playerState,
                enabled: enabled,
                onNext: {
                    Task { try? await container?.playerService.skipToNext() }
                },
                onPrevious: {
                    Task { try? await container?.playerService.skipToPrevious() }
                },
                commitDistance: compact ? 34 : 44,
                predictedDistance: compact ? 80 : 100,
                maxOffset: compact ? 64 : 90,
                resistance: 0.6
            )
        )
    }

    private func expandedBar(
        playerState: PlayerState,
        coverArtId: String,
        title: String,
        artist: String?,
        playbackAppearance: PlaybackControlAppearance,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: CassetteSpacing.m) {
                artwork(coverArtId: coverArtId, size: 36, isAvailable: isAvailable || !hasTrack)

                miniPlayerTitle(
                    playerState: playerState,
                    title: title,
                    subtitle: hasTrack ? (isAvailable ? artist : String(localized: "Reconnect to resume", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) : nil,
                    compact: false,
                    enabled: isAvailable && !isLiveStream && hasTrack
                )

                HStack(spacing: CassetteSpacing.s) {
                    playPauseButton(playbackAppearance: playbackAppearance, compact: false)
                    if isAvailable && !isLiveStream {
                        Button {
                            HapticFeedback.light.trigger()
                            Task { try? await container?.playerService.skipToNext() }
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .foregroundStyle(typoColor)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Skip to next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.vertical, CassetteSpacing.m)

            if hasTrack {
                if isLiveStream {
                    HStack(spacing: CassetteSpacing.xs) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CassetteSpacing.l)
                    .frame(height: 3)
                    .accessibilityHidden(true)
                } else {
                    // Isolate position observation so artwork/title/buttons don't rebuild at 2 Hz.
                    MiniPlayerProgressCapsule(
                        playerState: playerState,
                        isAvailable: isAvailable,
                        isHidden: showingFullPlayer
                    )
                }
            }
        }
        .background { miniPlayerSurface }
    }

    @ViewBuilder
    private func artwork(coverArtId: String, size: CGFloat, isAvailable: Bool) -> some View {
        if coverArtId.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        } else {
            CoverArtCard(id: coverArtId, size: size, cornerRadius: size * 0.22)
                .opacity(isAvailable ? 1.0 : 0.5)
        }
    }

    private func playPauseButton(playbackAppearance: PlaybackControlAppearance, compact: Bool) -> some View {
        Button {
            HapticFeedback.medium.trigger()
            Task { await container?.playerService.togglePlayPause() }
        } label: {
            Image(systemName: playbackAppearance.systemImage)
                .font(compact ? .body.weight(.semibold) : .title3)
                .foregroundStyle(typoColor)
                .opacity(hasTrack ? 1.0 : 0.35)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!hasTrack)
        .accessibilityLabel(playbackAppearance == .play ? String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Pause", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .accessibilityValue(playbackAppearance == .pause
            ? String(localized: "Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            : playbackAppearance == .loading
                ? String(localized: "Loading", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Paused", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }
}

/// Applies whole-bar tap-to-open only for compact / accessory layouts.
private struct MiniPlayerTapOpenModifier: ViewModifier {
    let enabled: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
        } else {
            content
        }
    }
}

/// Progress capsule leaf — sole mini-player reader of `playerState.position` (2 Hz).
private struct MiniPlayerProgressCapsule: View {
    let playerState: PlayerState
    let isAvailable: Bool
    let isHidden: Bool

    var body: some View {
        let progress: Double = {
            if isHidden || playerState.duration <= 0 { return 0 }
            return playerState.position / playerState.duration
        }()
        GeometryReader { geo in
            Capsule()
                .fill(isAvailable ? Color.cassetteAccent : Color.secondary.opacity(0.3))
                .frame(width: geo.size.width * CGFloat(progress), height: 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

// Reads tabViewBottomAccessoryPlacement from the environment and passes isInline
// down as a Bool so MiniPlayerAccessoryView doesn't need to declare the
// unavailable type at struct level.
@available(macOS 26.0, iOS 26.0, *)
private struct MiniPlayerPlacementReader<Content: View>: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement: TabViewBottomAccessoryPlacement?
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(placement == .inline)
    }
}
