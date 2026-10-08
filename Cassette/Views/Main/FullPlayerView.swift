// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import AppIntents
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

enum PlayerSurface { case player, lyrics, queue }

/// 9:11 ≈ 4.5:5.5 split for wide Now Playing when a side panel is open.
private struct DesktopPlayerColumnWidth: ViewModifier {
    let sidePanelOpen: Bool
    let span: Int

    func body(content: Content) -> some View {
        if sidePanelOpen {
            content.containerRelativeFrame(.horizontal, count: 20, span: span, spacing: CassetteSpacing.xl)
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func morphCover(_ enabled: Bool, in namespace: Namespace.ID, isSource: Bool) -> some View {
        if enabled {
            matchedGeometryEffect(id: "cover", in: namespace, isSource: isSource)
        } else {
            self
        }
    }

    @ViewBuilder
    func cassetteDesktopPlayerFooter<Footer: View>(
        enabled: Bool,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        if enabled {
            safeAreaInset(edge: .bottom, content: footer)
        } else {
            self
        }
    }
}

private struct PlayerThemeKey: Equatable {
    let coverId: String?
    let override: Color?
    let isActive: Bool
}

struct FullPlayerView: View {
    @Environment(\.appContainer) private var container
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cassette.visuals.animatedArtwork") private var animatedArtwork = true

    var onClose: (() -> Void)? = nil
    var openWithLyrics: Bool = false
    var openWithQueue: Bool = false

    @State private var vm = FullPlayerViewModel()
    @State private var surface: PlayerSurface = .player
    private var showLyrics: Bool { surface == .lyrics }
    @State private var lyricsViewModel: LyricsViewModel?
    @State private var atmosphereReady = false
    @State private var lyricsChromeAutoHideTask: Task<Void, Never>?
    /// Inactivity arms chrome hiding, but the actual transition waits until the
    /// next lyric line advances. This avoids controls disappearing mid-phrase.
    @State private var lyricsChromeHideArmed = false
    @Namespace private var morphNS

    #if os(iOS)
    /// Playing artwork nearly fills the phone width, matching the system Music player.
    private static let playerCoverHPaddingCompact: CGFloat = CassetteSpacing.xxl
    private static let playerCoverHPaddingRegular: CGFloat = 96
    /// Paused artwork keeps its layout slot and contracts around its center. Keeping the
    /// slot stable prevents the title, scrubber, and transport controls from jumping.
    private static let playerCoverPausedScale: CGFloat = 0.73
    private static let playerCoverToTitleGap: CGFloat = CassetteSpacing.xl
    private static let playerControlsSpacing: CGFloat = CassetteSpacing.l
    /// Align the compact player's lower chrome with the vertical rhythm of Music.app.
    private static let playerChromeYOffset: CGFloat = 12
    @State private var playerTopInset: CGFloat = 36
    @State private var playerViewportHeight: CGFloat = 844
    private var surfaceHeaderTopInset: CGFloat {
        max(playerTopInset - 41, 9)
    }

    private var playerCoverHPadding: CGFloat {
        horizontalSizeClass == .regular ? Self.playerCoverHPaddingRegular : Self.playerCoverHPaddingCompact
    }
    #endif

    private var usesDesktopDetail: Bool {
        CassetteWideLayout.usesDesktopDetail(horizontalSizeClass: horizontalSizeClass)
    }

    private var usesWidePlayerLayout: Bool {
        CassetteWideLayout.usesWidePlayerLayout(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    private func resolvedPlayerCoverId(_ playerState: PlayerState) -> String? {
        if playerState.isLiveStream { return playerState.currentRadio?.coverArt }
        // One resolution for every playback surface: the container's `playbackCoverId` prefers the id
        // the album was *prepared* under (the file that is actually on disk after a download or a
        // library cover preload), then the song's own cover. This screen used to fall back to the raw
        // song id, which missed the downloaded cover and re-fetched artwork from the server.
        return container?.playbackCoverId(for: playerState.currentTrack)
            ?? playerState.currentTrack?.effectiveCoverArtId
    }

    var body: some View {
        if let playerState = container?.playerState {
            let themeCoverId = resolvedPlayerCoverId(playerState)
            content(playerState)
                .appEntityIdentifier(nowPlayingEntityIdentifier(playerState))
                .task(id: PlayerThemeKey(coverId: themeCoverId, override: colorExtractor.colorOverride(for: themeCoverId ?? ""), isActive: scenePhase == .active)) {
                    guard scenePhase == .active else { return }
                    for attempt in 0..<3 {
                        if attempt > 0 {
                            do { try await Task.sleep(for: .seconds(attempt * 2)) } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        await vm.updateColors(for: themeCoverId, colorExtractor: colorExtractor, container: container)
                        guard let themeCoverId, vm.coverImage(for: themeCoverId) == nil else { return }
                    }
                }
                .task(id: playerState.currentTrack?.id) {
                    lyricsViewModel?.setVisible(false)
                    guard let track = playerState.currentTrack,
                          let serverId = container?.serverState.activeServer?.id,
                          let lyricsService = container?.lyricsService,
                          let playerService = container?.playerService else {
                        lyricsViewModel = nil
                        return
                    }
                    let newVM = LyricsViewModel(
                        songId: track.id,
                        serverId: serverId,
                        lyricsService: lyricsService,
                        playerService: playerService,
                        playerState: playerState,
                        match: LyricsMatchInfo(song: track)
                    )
                    lyricsViewModel = newVM
                    if showLyrics {
                        newVM.setVisible(true)
                    }
                    await newVM.load()
                    if newVM.shouldAutoDismissLyrics {
                        withAnimation(CassetteAnimation.surface) { surface = .player }
                    } else if showLyrics {
                        newVM.setVisible(true)
                        newVM.reconcileTracking()
                    }
                }
                .onChange(of: playerState.playbackState) { _, state in
                    lyricsViewModel?.reconcileTracking()
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(state == .playing)
                    #endif
                }
                .onChange(of: surface) { _, newSurface in
                    if newSurface == .lyrics {
                        if lyricsViewModel?.shouldAutoDismissLyrics == true {
                            surface = .player
                            return
                        }
                        lyricsViewModel?.setVisible(true)
                        showLyricsChromeTemporarily()
                    } else {
                        lyricsChromeAutoHideTask?.cancel()
                        lyricsChromeAutoHideTask = nil
                        lyricsChromeHideArmed = false
                        lyricsViewModel?.prefersHiddenChrome = false
                        lyricsViewModel?.setVisible(false)
                    }
                }
                .onChange(of: lyricsViewModel?.currentLineIndex) { oldLine, newLine in
                    guard showLyrics,
                          lyricsChromeHideArmed,
                          oldLine != newLine,
                          newLine != nil else { return }
                    lyricsChromeHideArmed = false
                    withAnimation(CassetteAnimation.chrome) {
                        lyricsViewModel?.prefersHiddenChrome = true
                    }
                }
                .onChange(of: lyricsViewModel?.shouldAutoDismissLyrics) { _, shouldDismiss in
                    if shouldDismiss == true, showLyrics {
                        withAnimation(CassetteAnimation.surface) { surface = .player }
                    }
                }
                .onAppear {
                    if openWithQueue, !playerState.isLiveStream {
                        surface = .queue
                    } else if openWithLyrics {
                        if lyricsViewModel?.shouldAutoDismissLyrics != true {
                            surface = .lyrics
                        }
                    }
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(playerState.playbackState == .playing)
                    #endif
                    atmosphereReady = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(usesWidePlayerLayout ? 320 : 180))
                        atmosphereReady = true
                    }
                }
                .onDisappear {
                    atmosphereReady = false
                    lyricsChromeAutoHideTask?.cancel()
                    lyricsChromeAutoHideTask = nil
                    lyricsChromeHideArmed = false
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(false)
                    #endif
                }
        }
    }

    @MainActor
    private func nowPlayingEntityIdentifier(_ playerState: PlayerState) -> EntityIdentifier? {
        guard #available(iOS 27.0, macOS 27.0, *),
              let song = playerState.currentTrack else { return nil }
        return OnscreenEntityAnnotation.songIdentifier(
            for: song,
            serverId: container?.serverState.activeServer?.id
        )
    }

    @ViewBuilder
    private func content(_ playerState: PlayerState) -> some View {
        let coverArtId = resolvedPlayerCoverId(playerState) ?? ""
        let dominant: Color = {
            if vm.dominantColor != .black { return vm.dominantColor }
            let source = colorExtractor.cachedColor(for: coverArtId) ?? .black
            if source == .black || source == .clear { return .black }
            return CoverColorRefiner.playerAtmosphere(from: source).pageColor
        }()
        let isPlaying = playerState.playbackState.hasPlaybackIntent
        let showingQueue = isQueueVisible(playerState)

        surfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying,
                     showingQueue: showingQueue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cassetteContentWidth(.fill)
            .cassetteDesktopPlayerFooter(enabled: {
                #if os(macOS)
                true
                #else
                usesWidePlayerLayout
                #endif
            }()) {
                sharedFooter(playerState)
            }
            .environment(\.cassettePlayingAccent, CassetteColors.accentForeground(on: dominant))
        .background {
            BeatReactiveBackgroundView(
                dominant: dominant,
                top: vm.atmosphereTop == .black ? dominant : vm.atmosphereTop,
                mid: vm.atmosphereMid == .black ? dominant : vm.atmosphereMid,
                bottom: vm.atmosphereBottom == .black ? dominant : vm.atmosphereBottom,
                isPlaying: isPlaying,
                coverImage: atmosphereReady ? vm.coverImage(for: coverArtId) : nil,
                freezeBeat: !animatedArtwork || !atmosphereReady || showLyrics || showingQueue || scenePhase != .active
            )
        }
    }

    @ViewBuilder
    private func surfaceStack(_ playerState: PlayerState, coverArtId: String, isPlaying: Bool,
                              showingQueue: Bool) -> some View {
        #if os(iOS)
        if usesWidePlayerLayout {
            desktopSurfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying, showingQueue: showingQueue)
        } else {
        let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                flowGap((showLyrics || showingQueue) ? surfaceHeaderTopInset : playerTopInset)

                ZStack {
                    if showLyrics, let lyricsVM = lyricsViewModel {
                        flowingLyricsContent(
                            playerState,
                            lyricsVM: lyricsVM,
                            hideChrome: hideChrome
                        )
                    } else if showingQueue {
                        flowingQueueContent(playerState)
                    }

                    flowingCover(
                        playerState,
                        coverArtId: coverArtId,
                        isSource: surface == .player,
                        isPlaying: isPlaying
                    )
                    .allowsHitTesting(surface == .player)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: showLyrics
                        ? (hideChrome
                            ? max(300, playerViewportHeight)
                            : max(300, min(440, playerViewportHeight * 0.50)))
                        : .infinity
                )
                .animation(CassetteAnimation.chrome, value: hideChrome)

                flowGap(Self.playerCoverToTitleGap)
                    .frame(maxHeight: hideChrome ? 0 : Self.playerCoverToTitleGap)
                    .opacity(hideChrome ? 0 : 1)

                VStack(spacing: 0) {
                    if surface == .player {
                        TrackInfoSection(
                            playerState: playerState,
                            container: container,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            glassTint: vm.glassTint,
                            layout: .standard,
                            showLyrics: false,
                            showsTranslateBelowMenu: false,
                            showsFavoriteStar: true,
                            lyricsViewModel: lyricsViewModel
                        )
                        .id(playerState.currentTrack?.id ?? "empty")
                        .padding(.horizontal, CassetteSpacing.l)
                    }

                    if (surface == .player || surface == .lyrics || surface == .queue), !playerState.isLiveStream {
                        ScrubberView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            isExpensiveNetwork: container?.serverState.isExpensive ?? false
                        )
                        .padding(.horizontal, CassetteSpacing.l)
                        .padding(.top, showingQueue ? 0 : CassetteSpacing.m)
                        .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                        .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                    }

                    if surface == .player || surface == .lyrics || surface == .queue {
                        PlaybackControlsView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            isPlaybackAvailable: playerState.isPlaybackAvailable,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor
                        )
                        .padding(.top, Self.playerControlsSpacing)

                        if dynamicTypeSize < .accessibility1 {
                            VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                                .padding(.horizontal, CassetteSpacing.l)
                                .padding(.top, Self.playerControlsSpacing + 6)
                        }
                    }
                }
                .opacity(hideChrome ? 0 : 1)
                .frame(maxHeight: hideChrome ? 0 : nil)
                .clipped()
                .allowsHitTesting(!hideChrome)
                .accessibilityHidden(hideChrome)
                .animation(CassetteAnimation.chrome, value: hideChrome)
                .offset(y: Self.playerChromeYOffset)

                // All compact surfaces share one lower-chrome baseline so switching between
                // player, lyrics, and queue never makes the controls jump upward.
                flowGap(showingQueue ? CassetteSpacing.xs : 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(CassetteAnimation.surface, value: surface)

            BottomToolbar(
                surface: $surface,
                isLiveStream: playerState.isLiveStream,
                lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                lyricsViewModel: lyricsViewModel,
                translateEnabled: false,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                playerState: playerState
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.s)
            .padding(.bottom, CassetteSpacing.l)
            .opacity(hideChrome ? 0 : 1)
            .frame(maxHeight: hideChrome ? 0 : nil)
            .clipped()
            .allowsHitTesting(!hideChrome)
            .accessibilityHidden(hideChrome)
            .animation(CassetteAnimation.chrome, value: hideChrome)
            .offset(y: Self.playerChromeYOffset)
        }
        .overlay(alignment: .top) {
            topBar
                .padding(.top, 2)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        playerTopInset = max(geo.safeAreaInsets.top, 0) + 14
                        playerViewportHeight = geo.size.height
                    }
                    .onChange(of: geo.safeAreaInsets.top) { _, top in
                        playerTopInset = max(top, 0) + 14
                    }
                    .onChange(of: geo.size.height) { _, height in
                        playerViewportHeight = height
                    }
            }
        }
        } // end compact flowing
        #else
        desktopSurfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying, showingQueue: showingQueue)
        #endif
    }

    @ViewBuilder
    private func desktopSurfaceStack(
        _ playerState: PlayerState,
        coverArtId: String,
        isPlaying: Bool,
        showingQueue: Bool
    ) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 2)

            desktopPlayerSurface(
                playerState,
                coverArtId: coverArtId,
                isPlaying: isPlaying,
                showingQueue: showingQueue
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func desktopPlayerSurface(
        _ playerState: PlayerState,
        coverArtId: String,
        isPlaying: Bool,
        showingQueue: Bool
    ) -> some View {
        let sidePanelOpen = showLyrics || showingQueue
        let isPhoneLandscape = horizontalSizeClass == .compact && verticalSizeClass == .compact
        let columnGap = CassetteSpacing.xl
        let coverTopInset: CGFloat = 112
        let coverSize: CGFloat = {
            if isPhoneLandscape { return CassetteWideLayout.playerCoverCapCompactHeight }
            return sidePanelOpen ? 380 : 440
        }()
        let controlsWidth = coverSize + 48

        HStack(alignment: sidePanelOpen ? .top : .center, spacing: columnGap) {
            if !sidePanelOpen { Spacer(minLength: 0) }

            VStack(spacing: CassetteSpacing.m) {
                Spacer()
                    .frame(height: coverTopInset)

                CoverArtView(id: coverArtId, size: 700, initialImage: vm.coverImage(for: coverArtId))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                    .scaleEffect(isPlaying ? 1.0 : 0.92)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)
                    .trackSkipSwipe(playerState: playerState)

                Spacer(minLength: CassetteSpacing.m)

                VStack(spacing: CassetteSpacing.m) {
                    TrackInfoSection(
                        playerState: playerState,
                        container: container,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor,
                        glassTint: vm.glassTint,
                        layout: .standard,
                        showLyrics: false,
                        showsTranslateBelowMenu: false,
                        showsFavoriteStar: false,
                        lyricsViewModel: lyricsViewModel
                    )
                    .frame(maxWidth: controlsWidth)

                    if !playerState.isLiveStream {
                        ScrubberView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            isExpensiveNetwork: container?.serverState.isExpensive ?? false
                        )
                        .frame(maxWidth: controlsWidth)
                        .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                        .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                    }

                    PlaybackControlsView(
                        playerState: playerState,
                        playerService: container?.playerService,
                        isPlaybackAvailable: playerState.isPlaybackAvailable,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor,
                        showsShuffleRepeat: !playerState.isLiveStream
                    )
                    .frame(maxWidth: controlsWidth + 16)
                    .padding(.top, CassetteSpacing.s)

                    if atmosphereReady, dynamicTypeSize < .accessibility1 {
                        VolumeSection(
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor
                        )
                        .frame(maxWidth: controlsWidth)
                        .padding(.top, CassetteSpacing.s)
                    }
                }
                .frame(maxWidth: controlsWidth + 16)
            }
            .frame(maxWidth: sidePanelOpen ? .infinity : controlsWidth + 32)
            .frame(maxHeight: .infinity, alignment: .top)
            .modifier(DesktopPlayerColumnWidth(sidePanelOpen: sidePanelOpen, span: 9))

            if showLyrics {
                desktopLyricsPanel(playerState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(DesktopPlayerColumnWidth(sidePanelOpen: true, span: 11))
            } else if showingQueue {
                desktopQueuePanel(playerState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(DesktopPlayerColumnWidth(sidePanelOpen: true, span: 11))
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, CassetteSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func desktopLyricsPanel(_ playerState: PlayerState) -> some View {
        Group {
            if let lyricsVM = lyricsViewModel {
                LyricsView(viewModel: lyricsVM, density: .spacious)
            } else {
                ContentUnavailableView(
                    "No Lyrics",
                    systemImage: "text.quote",
                    description: Text("Play a song to see lyrics here.")
                )
                .foregroundStyle(vm.secondaryContentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, CassetteSpacing.l)
    }

    private func shouldShowLyricsTranslate(_ lyricsVM: LyricsViewModel) -> Bool {
        guard LyricsTranslationSettings.shared.isTranslationEnabled else { return false }
        guard case .loaded = lyricsVM.state else { return false }
        return lyricsVM.needsTranslation
    }

    @ViewBuilder
    private func desktopQueuePanel(_ playerState: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CassetteSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Continue Playing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.cassetteSectionTitle)
                        .foregroundStyle(vm.contentColor)
                    if let album = playerState.currentTrack?.albumName, !album.isEmpty {
                        Text("From \(album)")
                            .font(.cassetteCaption)
                            .foregroundStyle(vm.secondaryContentColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: CassetteSpacing.m) {
                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
                    } label: {
                        Image(systemName: "infinity")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(playerState.isAutoExtendEnabled ? Color.cassetteAccent : vm.secondaryContentColor)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Auto-extend with Smart Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

                    Button {
                        HapticFeedback.light.trigger()
                        Task { await container?.playerService.toggleShuffle() }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(playerState.isShuffled ? Color.cassetteAccent : vm.secondaryContentColor)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playerState.isShuffled ? String(localized: "Shuffle On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Shuffle Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
            }
            .padding(.trailing, CassetteSpacing.l)
            .padding(.bottom, CassetteSpacing.m)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: true
            )
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, CassetteSpacing.l)

            queueStatusLine(playerState)
                .padding(.trailing, CassetteSpacing.l)
                .padding(.vertical, CassetteSpacing.s)
        }
    }

    /// Shared by both platforms: iOS shows the lyrics surface inline while macOS
    /// uses a side panel, but the chrome auto-hide behaviour is identical.
    private func showLyricsChromeTemporarily() {
        guard surface == .lyrics else { return }
        lyricsChromeAutoHideTask?.cancel()
        lyricsChromeHideArmed = false
        if lyricsViewModel?.prefersHiddenChrome == true {
            withAnimation(CassetteAnimation.chrome) {
                lyricsViewModel?.prefersHiddenChrome = false
            }
        }
        lyricsChromeAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, surface == .lyrics else { return }
            // Do not hide at an arbitrary timer boundary. Once the user has been idle,
            // wait for the next timed lyric transition and hide there instead.
            lyricsChromeHideArmed = true
        }
    }

    #if os(iOS)
    private func flowGap(_ floor: CGFloat) -> some View {
        Color.clear.frame(minHeight: floor, maxHeight: floor)
    }

    private func flowingCover(
        _ playerState: PlayerState,
        coverArtId: String,
        isSource: Bool,
        isPlaying: Bool
    ) -> some View {
        GeometryReader { geo in
            let side = min(
                max(0, geo.size.width - playerCoverHPadding * 2),
                geo.size.height
            )
            let corner = max(12, side * 0.035)
            let scale: CGFloat = isSource
                ? (isPlaying ? 1.0 : Self.playerCoverPausedScale)
                : 1.0
            let artSide: CGFloat = isSource ? side : 64
            let artCorner: CGFloat = isSource ? corner : CassetteCornerRadius.standard

            CoverArtView(id: coverArtId, size: 600, initialImage: vm.coverImage(for: coverArtId), contentMode: .fill)
                .frame(width: artSide, height: artSide)
                .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
                .shadow(color: .black.opacity(isSource ? 0.4 : 0), radius: isPlaying ? 28 : 18, y: isPlaying ? 14 : 10)
                .scaleEffect(scale)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84),
                    value: isPlaying
                )
                .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: isSource)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func flowingLyricsContent(
        _ playerState: PlayerState,
        lyricsVM: LyricsViewModel,
        hideChrome: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: CassetteSpacing.m) {
                Color.clear
                    .frame(width: 64, height: 64)
                    .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: surface == .lyrics)

                TrackInfoSection(
                    playerState: playerState,
                    container: container,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint,
                    layout: .lyricsHeader,
                    showLyrics: true,
                    showsTranslateBelowMenu: false,
                    showsCoverThumbnail: false,
                    showsFavoriteStar: true,
                    lyricsViewModel: lyricsVM
                )
                .id("lyrics-header-\(playerState.currentTrack?.id ?? "empty")")
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.xs)
            .padding(.bottom, CassetteSpacing.s)

            LyricsView(
                viewModel: lyricsVM,
                bottomChromeInset: hideChrome ? 20 : 8,
                onInteraction: showLyricsChromeTemporarily,
                consumesLineTapToRevealChrome: hideChrome
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            // Fade the scrolling lyrics into the header without placing a material layer
            // over the text. The previous ultra-thin-material strip refracted the lines and
            // looked like a separate, foggy band between the metadata and lyrics.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.18), location: 0.24),
                            .init(color: .black.opacity(0.72), location: 0.68),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 54)

                    Rectangle().fill(.black)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !hideChrome, shouldShowLyricsTranslate(lyricsVM) {
                    CassetteLyricsTranslateButton(
                        lyricsViewModel: lyricsVM,
                        contentColor: vm.contentColor,
                        buttonSize: 46,
                        iconSize: 16
                    )
                    .padding(.leading, CassetteSpacing.m)
                    .padding(.bottom, CassetteSpacing.s)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(CassetteAnimation.chrome, value: hideChrome)
        }
    }

    private func flowingQueueContent(_ playerState: PlayerState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: CassetteSpacing.m) {
                Color.clear
                    .frame(width: 64, height: 64)
                    .matchedGeometryEffect(id: "queueCover", in: morphNS, isSource: surface == .queue)

                TrackInfoSection(
                    playerState: playerState,
                    container: container,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint,
                    layout: .lyricsHeader,
                    showLyrics: false,
                    showsCoverThumbnail: false,
                    showsFavoriteStar: true,
                    lyricsViewModel: nil
                )
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.s)

            queuePills(playerState)
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.top, CassetteSpacing.m)
                .padding(.bottom, CassetteSpacing.s)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: true
            )
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

        }
    }
    #endif

    private func isQueueVisible(_ playerState: PlayerState) -> Bool {
        surface == .queue && !playerState.isLiveStream
    }

    @ViewBuilder
    private func queueSurface(_ playerState: PlayerState, coverArtId: String) -> some View {
        VStack(spacing: 0) {
            collapsedTrackHeader(playerState, coverArtId: coverArtId)
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.top, CassetteSpacing.xs)

            queuePills(playerState)
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.top, CassetteSpacing.m)
                .padding(.bottom, CassetteSpacing.s)

            InlineQueueList(
                playerState: playerState,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                loadArtwork: isQueueVisible(playerState)
            )
            .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            queueStatusLine(playerState)
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.vertical, CassetteSpacing.s)
        }
    }

    private func collapsedTrackHeader(_ playerState: PlayerState, coverArtId: String) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtView(id: coverArtId, size: 120)
                .frame(width: 64, height: 64)
                .cassetteCoverStyle(cornerRadius: CassetteCornerRadius.standard)
                .morphCover(!reduceMotion, in: morphNS, isSource: isQueueVisible(playerState))

            TrackInfoSection(
                playerState: playerState,
                container: container,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                glassTint: vm.glassTint,
                layout: .standard,
                showLyrics: showLyrics,
                showsFavoriteStar: true,
                lyricsViewModel: lyricsViewModel
            )
        }
    }

    private func queuePills(_ playerState: PlayerState) -> some View {
        HStack(spacing: CassetteSpacing.s) {
            queuePill(systemImage: "shuffle", isActive: playerState.isShuffled,
                      label: playerState.isShuffled ? "Shuffle On" : "Shuffle Off") {
                Task { await container?.playerService.toggleShuffle() }
            }
            queuePill(systemImage: playerState.repeatMode.systemImage, isActive: playerState.repeatMode != .off,
                      label: "Repeat") {
                Task { await container?.playerService.setRepeatMode(playerState.repeatMode.next) }
            }
            queuePill(systemImage: "infinity", isActive: playerState.isAutoExtendEnabled,
                      label: "Auto-extend with Smart Shuffle") {
                Task { await container?.playerService.setAutoExtendEnabled(!playerState.isAutoExtendEnabled) }
            }
            let crossfadeEnabled = (container?.crossfadeSettings.duration ?? 0) > 0
            queuePill(systemImage: "circle.circle", isActive: crossfadeEnabled,
                      label: "Crossfade") {
                guard let settings = container?.crossfadeSettings else { return }
                settings.duration = crossfadeEnabled ? 0 : 4
                Task { await container?.playerService.crossfadeSettingsDidChange() }
            }
        }
    }

    private func queuePill(systemImage: String, isActive: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.light.trigger()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : vm.secondaryContentColor)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .cassettePlainCapsule(
                    fill: isActive ? CassetteColors.accent.opacity(0.70) : vm.contentColor.opacity(0.14)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func upNextHeader(_ playerState: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Up Next")
                .font(.cassetteSectionTitle)
                .foregroundStyle(vm.contentColor)
            if let album = playerState.currentTrack?.albumName, !album.isEmpty {
                Text(album)
                    .font(.cassetteCaption)
                    .foregroundStyle(vm.secondaryContentColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueStatusLine(_ playerState: PlayerState) -> some View {
        let upNextCount = max(playerState.queue.count - playerState.currentIndex - 1, 0)
        var bits: [String] = ["\(upNextCount) up next"]
        if playerState.repeatMode == .all {
            bits.append("Repeating all")
        } else if playerState.repeatMode == .one {
            bits.append("Repeating one")
        }
        if playerState.isShuffled { bits.append("Shuffled") }
        if playerState.isAutoExtendEnabled { bits.append("Auto-extend on") }
        return Text(bits.joined(separator: " · "))
            .font(.cassetteCaption)
            .foregroundStyle(vm.secondaryContentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    @ViewBuilder
    private func sharedFooter(_ playerState: PlayerState) -> some View {
        VStack(spacing: 0) {
            if surface == .player, !usesWidePlayerLayout {
                if !playerState.isLiveStream {
                    ScrubberView(
                        playerState: playerState,
                        playerService: container?.playerService,
                        contentColor: vm.contentColor,
                        secondaryContentColor: vm.secondaryContentColor,
                        isExpensiveNetwork: container?.serverState.isExpensive ?? false
                    )
                    .padding(.horizontal, CassetteSpacing.l)
                    .padding(.top, CassetteSpacing.m)
                    .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                    .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                }

                PlaybackControlsView(
                    playerState: playerState,
                    playerService: container?.playerService,
                    isPlaybackAvailable: playerState.isPlaybackAvailable,
                    contentColor: vm.contentColor,
                    secondaryContentColor: vm.secondaryContentColor
                )
                .padding(.top, CassetteSpacing.s)

                if dynamicTypeSize < .accessibility1 {
                    VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                        .padding(.horizontal, CassetteSpacing.l)
                        .padding(.top, CassetteSpacing.s)
                }
            }

            BottomToolbar(
                surface: $surface,
                isLiveStream: playerState.isLiveStream,
                lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                lyricsViewModel: lyricsViewModel,
                translateEnabled: lyricsViewModel.map(shouldShowLyricsTranslate) ?? false,
                contentColor: vm.contentColor,
                secondaryContentColor: vm.secondaryContentColor,
                playerState: playerState,
                spreadToEdges: usesWidePlayerLayout
            )
            .padding(.horizontal, usesWidePlayerLayout ? CassetteSpacing.xxxl : CassetteSpacing.l)
            .padding(.top, usesWidePlayerLayout ? CassetteSpacing.xs : CassetteSpacing.m)
            .padding(.bottom, usesWidePlayerLayout ? CassetteSpacing.xxl : CassetteSpacing.xxl)
            .safeAreaPadding(.horizontal, usesWidePlayerLayout ? CassetteSpacing.l : 0)
        }
    }

    private var topBar: some View {
        ZStack(alignment: .top) {
            Button {
                closePlayer()
            } label: {
                Capsule()
                    .fill(vm.contentColor.opacity(0.55))
                    .frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                    .padding(.top, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
			.accessibilityLabel(String(localized: "Close player", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

        }
    }

    private func closePlayer() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
