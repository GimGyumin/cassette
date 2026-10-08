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
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimatingSwipe = false

    private let swipeThreshold: CGFloat = 100
    private let velocityThreshold: CGFloat = 200

    // Apple Music behaviour: the bar follows the frontmost themed page. `MainTabView` injects the
    // page-derived scheme (`resolvedColorScheme`) here, so `.primary` / `.secondary` flip with the
    // page instead of being pinned to one appearance.
    private var typoColor: Color { .primary }
    private var typoSecondaryColor: Color { .secondary }

    /// Surface wash behind the bar content.
    ///
    /// iOS 26 draws the tab-bar accessory glass *itself*, and resolves it from the app appearance,
    /// while this bar's content follows the themed page. When those disagree — a light album page
    /// inside a dark app, or the inverse — white-on-white / black-on-black was the result (the
    /// mini player read as a washed-out pill with unreadable text). A wash in the content's own
    /// direction keeps the bar legible whatever the system put behind it.
    private var surfaceWash: Color {
        colorScheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.55)
    }

    /// Current track's artwork colour, so the bar carries the album like every page does. Re-read
    /// on each render, which is what makes the tint follow track changes immediately.
    private var albumTint: Color? {
        guard let track = container?.playerState.currentTrack else { return nil }
        let coverArtId = container?.playbackCoverId(for: track) ?? track.effectiveCoverArtId
        return container?.dominantColorExtractor.cachedColor(for: coverArtId)
    }

    @ViewBuilder
    private var miniPlayerSurface: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // tabViewBottomAccessory supplies the native Liquid Glass. An opaque material capsule
            // here would cover that system surface and make the player look like a flat pill.
            Capsule()
                .fill((albumTint ?? .clear).opacity(0.10))
                .allowsHitTesting(false)
        } else {
            Capsule()
                .fill(surfaceWash)
                .overlay(Capsule().fill((albumTint ?? .clear).opacity(0.18)))
                .allowsHitTesting(false)
        }
        #else
        Capsule()
            .fill(surfaceWash)
            .overlay(Capsule().fill((albumTint ?? .clear).opacity(0.18)))
            .allowsHitTesting(false)
        #endif
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
                if #available(macOS 26.0, iOS 26.0, *), !usesPadFloatingBar {
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
            if usesPadFloatingBar {
                padFloatingBar(
                    playerState: playerState,
                    coverArtId: coverArtId,
                    title: title,
                    artist: artist,
                    playbackAppearance: playbackAppearance,
                    isAvailable: isAvailable,
                    isLiveStream: isLiveStream
                )
                .transition(.opacity)
            } else if isInline {
                inlineBar(
                    coverArtId: coverArtId,
                    title: title,
                    artist: artist,
                    playbackAppearance: playbackAppearance,
                    isAvailable: isAvailable
                )
                .transition(.opacity)
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
                .transition(.opacity)
            }
        }
        .animation(CassetteAnimation.interactive, value: isInline)
        .offset(x: dragOffset)
        .opacity(1.0 - min(abs(dragOffset) / 200, 0.4))
        .modifier(MiniPlayerTapOpenModifier(
            enabled: !usesPadFloatingBar && hasTrack,
            open: { showingFullPlayer = true }
        ))
        .gesture(isAvailable && !isLiveStream && !usesPadFloatingBar ? swipeSkipGesture : nil)
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
        .frame(height: 64)
        .frame(maxWidth: 920)
        .background { padCapsuleBackground }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 16, y: 4)
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
                    .foregroundStyle(typoColor.opacity(isAvailable ? 1 : 0.35))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(!isAvailable)
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
        coverArtId: String,
        title: String,
        artist: String?,
        isAvailable: Bool,
        isLiveStream: Bool
    ) -> some View {
        Button {
            guard hasTrack else { return }
            showingFullPlayer = true
        } label: {
            HStack(spacing: 12) {
                artwork(coverArtId: coverArtId, size: 44, isAvailable: isAvailable || !hasTrack)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(typoColor)
                        .lineLimit(1)
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

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack)
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
        coverArtId: String,
        title: String,
        artist: String?,
        playbackAppearance: PlaybackControlAppearance,
        isAvailable: Bool
    ) -> some View {
        HStack(spacing: 10) {
            artwork(coverArtId: coverArtId, size: 28, isAvailable: isAvailable || !hasTrack)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(typoColor)
                    .lineLimit(1)
                if let artist, hasTrack {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(typoSecondaryColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            playPauseButton(playbackAppearance: playbackAppearance, isAvailable: isAvailable, compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { miniPlayerSurface }
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cassetteCellTitle)
                        .foregroundStyle(typoColor)
                        .lineLimit(1)
                    if hasTrack {
                        if !isAvailable {
                            Text("Reconnect to resume")
                                .font(.cassetteCaption)
                                .foregroundStyle(typoSecondaryColor)
                                .lineLimit(1)
                        } else if let artist {
                            Text(artist)
                                .font(.cassetteCaption)
                                .foregroundStyle(typoSecondaryColor)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: CassetteSpacing.s) {
                    playPauseButton(playbackAppearance: playbackAppearance, isAvailable: isAvailable, compact: false)
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

    private func playPauseButton(playbackAppearance: PlaybackControlAppearance, isAvailable: Bool, compact: Bool) -> some View {
        Button {
            HapticFeedback.medium.trigger()
            Task { await container?.playerService.togglePlayPause() }
        } label: {
            Image(systemName: playbackAppearance.systemImage)
                .font(compact ? .body.weight(.semibold) : .title3)
                .foregroundStyle(typoColor)
                .opacity(isAvailable ? 1.0 : 0.35)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!isAvailable)
        .accessibilityLabel(playbackAppearance == .play ? String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Pause", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    private var swipeSkipGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isAnimatingSwipe else { return }
                let h = value.translation.width
                guard abs(h) > abs(value.translation.height) else { return }
                withAnimation(.interactiveSpring()) {
                    dragOffset = h
                }
            }
            .onEnded { value in
                guard !isAnimatingSwipe else { return }
                let h = value.translation.width
                let velocity = value.velocity.width
                guard abs(h) > abs(value.translation.height) else {
                    bounceback()
                    return
                }

                let triggeredNext = h < -swipeThreshold || velocity < -velocityThreshold
                let triggeredPrev = h > swipeThreshold || velocity > velocityThreshold

                if triggeredNext || triggeredPrev {
                    commitSwipe(goNext: triggeredNext)
                } else {
                    bounceback()
                }
            }
    }

    private func commitSwipe(goNext: Bool) {
        isAnimatingSwipe = true
        HapticFeedback.medium.trigger()

        let exitOffset: CGFloat = goNext ? -300 : 300
        withAnimation(.easeIn(duration: 0.18)) {
            dragOffset = exitOffset
        }

        Task {
            if goNext {
                try? await container?.playerService.skipToNext()
            } else {
                try? await container?.playerService.skipToPrevious()
            }

            let entryOffset: CGFloat = goNext ? 300 : -300
            await MainActor.run {
                dragOffset = entryOffset
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    dragOffset = 0
                }
                isAnimatingSwipe = false
            }
        }
    }

    private func bounceback() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            dragOffset = 0
        }
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
