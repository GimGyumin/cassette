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
    let serverID: UUID?
    let uploadVersion: Int
    let artworkRevision: UInt64
    let allowsArtworkNetwork: Bool
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
    /// The same "Immersive Album Artwork" preference that extends album pages.
    /// When enabled, the compact iPhone player uses an artwork-led layout.
    @AppStorage("cassette.visuals.immersiveAlbums") private var immersiveArtwork = true

    var onClose: (() -> Void)? = nil
    var openWithLyrics: Bool = false
    var openWithQueue: Bool = false

    @State private var fallbackViewModel = FullPlayerViewModel()
    private var vm: FullPlayerViewModel { container?.fullPlayerViewModel ?? fallbackViewModel }
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    /// Local high-quality artwork resolved across the track/album/download candidates.
    @State private var resolvedArtworkID: String?
    @State private var resolvedArtworkImage: PlatformImage?
    @State private var resolvedArtworkTrackID: String?
    @State private var surface: PlayerSurface = .player
    private var showLyrics: Bool { surface == .lyrics }
    @State private var lyricsViewModel: LyricsViewModel?
    @State private var lyricsVisibilityOwner = UUID()
    @State private var atmosphereReady = false
    @State private var isRotating = false
    @State private var lyricsChromeAutoHideTask: Task<Void, Never>?
    @State private var atmosphereTask: Task<Void, Never>?
    @Namespace private var morphNS

    #if os(iOS)
    /// Playing artwork nearly fills the phone width, matching the system Music player.
    private static let playerCoverHPaddingCompact: CGFloat = CassetteSpacing.xxl
    private static let playerCoverHPaddingRegular: CGFloat = 96
    /// Paused artwork keeps its layout slot and contracts around its center. Keeping the
    /// slot stable prevents the title, scrubber, and transport controls from jumping.
    private static let playerCoverPausedScale = PlayerArtworkPlaybackModifier.pausedScale
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

    private var usesPhoneLandscape: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private var usesWidePlayerLayout: Bool {
        CassetteWideLayout.usesWidePlayerLayout(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    /// Compact iPhone portrait Now Playing only. Lyrics/queue and the wide player
    /// keep their existing layouts and blurred atmosphere.
    private var usesImmersivePortraitLayout: Bool {
        #if os(iOS)
        immersiveArtwork && !usesWidePlayerLayout && !usesPhoneLandscape
            && !dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private var showsImmersivePlayer: Bool { usesImmersivePortraitLayout && surface == .player }

    private func resolvedPlayerCoverId(_ playerState: PlayerState) -> String? {
        if playerState.isLiveStream { return playerState.currentRadio?.coverArt }
        if playerState.currentTrack?.id == resolvedArtworkTrackID, let resolvedArtworkID {
            return resolvedArtworkID
        }
        // Fallback until the local high-quality candidates resolve: the playback
        // cover (prepared album cover when the index knows it), then the song's
        // effective cover. The resolved id above wins once a downloaded original
        // or local hero is available.
        return container?.playbackCoverId(for: playerState.currentTrack)
            ?? playerState.currentTrack?.effectiveCoverArtId
    }

    private func playerCoverImage(for coverID: String) -> PlatformImage? {
        if coverID == resolvedArtworkID, let resolvedArtworkImage {
            return resolvedArtworkImage
        }
        if vm.themeColor(for: coverID, serverID: container?.serverState.activeServer?.id) != nil,
           let image = vm.coverImage(for: coverID) { return image }
        return container?.artworkImageCache.cachedImage(for: coverID, tier: .hero)
            ?? container?.artworkImageCache.cachedImage(for: coverID, tier: .thumb)
    }

    var body: some View {
        if let playerState = container?.playerState {
            let themeCoverId = resolvedPlayerCoverId(playerState)
            let themeKey = PlayerThemeKey(
                coverId: themeCoverId,
                override: colorExtractor.colorOverride(for: themeCoverId ?? ""),
                isActive: scenePhase == .active,
                serverID: container?.serverState.activeServer?.id,
                uploadVersion: coverArtUploadVersion,
                artworkRevision: vm.artworkRevision,
                allowsArtworkNetwork: container?.artworkImageCache.allowsNetworkDownloads == true
            )
            content(playerState)
                #if os(iOS)
                .background {
                    PlayerRotationObserver { rotating in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { isRotating = rotating }
                    }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
                #endif
                // Rotation geometry snaps to the new viewport, while leaf animations
                // (notably play/pause artwork scaling) retain their own transactions.
                .animation(nil, value: isRotating)
                .appEntityIdentifier(nowPlayingEntityIdentifier(playerState))
                .task(id: themeKey) {
                    guard scenePhase == .active else { return }
                    for attempt in 0..<3 {
                        if attempt > 0 {
                            do { try await Task.sleep(for: .seconds(attempt * 2)) } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        await vm.updateColors(
                            for: themeCoverId, colorExtractor: colorExtractor,
                            container: container, uploadVersion: coverArtUploadVersion
                        )
                        guard let themeCoverId, vm.coverImage(for: themeCoverId) == nil else { return }
                    }
                }
                .task(id: playerState.currentTrack?.id) {
                    lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
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
                    newVM.setScenePhase(scenePhase)
                    newVM.setVisible(showLyrics, owner: lyricsVisibilityOwner)
                    if showLyrics { showLyricsChromeTemporarily() }
                    await newVM.load()
                    guard !Task.isCancelled, lyricsViewModel === newVM,
                          playerState.currentTrack?.id == track.id else { return }
                    if newVM.shouldAutoDismissLyrics {
                        withAnimation(CassetteAnimation.surface) { surface = .player }
                    } else if showLyrics {
                        newVM.reconcileTracking()
                    }
                }
                .task(id: "\(playerState.currentTrack?.id ?? "none")-\(coverArtUploadVersion)-\(vm.artworkRevision)") {
                    let track = playerState.currentTrack
                    let trackID = track?.id
                    if resolvedArtworkTrackID != trackID {
                        resolvedArtworkTrackID = nil
                        resolvedArtworkID = nil
                        resolvedArtworkImage = nil
                    }
                    guard let track,
                          let local = await container?.localPlaybackArtwork(for: track),
                          !Task.isCancelled,
                          playerState.currentTrack?.id == track.id else { return }
                    resolvedArtworkTrackID = track.id
                    resolvedArtworkID = local.id
                    resolvedArtworkImage = local.image
                }
                .onChange(of: scenePhase) { _, phase in
                    lyricsViewModel?.setScenePhase(phase)
                    if phase == .active { showLyricsChromeTemporarily() }
                    else { lyricsChromeAutoHideTask?.cancel() }
                }
                .onChange(of: playerState.playbackState) { _, state in
                    lyricsViewModel?.reconcileTracking()
                    #if os(iOS)
                    MusicHapticsController.shared.setPlaying(state == .playing)
                    #endif
                }
                .onChange(of: surface) { _, newSurface in
                    Logger.ui.info("[PLAYER-SURFACE] run=\(RuntimeDiagnostics.sessionID, privacy: .public) surface=\(String(describing: newSurface), privacy: .public) animated_artwork=\(animatedArtwork, privacy: .public) budget=\(CassettePerformance.budget.summary, privacy: .public)")
                    if newSurface == .lyrics {
                        if lyricsViewModel?.shouldAutoDismissLyrics == true {
                            surface = .player
                            return
                        }
                        lyricsViewModel?.setVisible(true, owner: lyricsVisibilityOwner)
                        showLyricsChromeTemporarily()
                    } else {
                        lyricsChromeAutoHideTask?.cancel()
                        lyricsChromeAutoHideTask = nil
                        lyricsViewModel?.prefersHiddenChrome = false
                        lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
                    }
                }
                .onChange(of: lyricsViewModel?.shouldAutoDismissLyrics) { _, shouldDismiss in
                    if shouldDismiss == true, showLyrics {
                        withAnimation(CassetteAnimation.surface) { surface = .player }
                    }
                }
                .onAppear {
                    Logger.ui.info("[PLAYER-VIEW] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=appear animated_artwork=\(animatedArtwork, privacy: .public) budget=\(CassettePerformance.budget.summary, privacy: .public)")
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
                    lyricsViewModel?.setVisible(showLyrics, owner: lyricsVisibilityOwner)
                    atmosphereReady = false
                    atmosphereTask?.cancel()
                    atmosphereTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(usesWidePlayerLayout ? 320 : 180)) } catch { return }
                        atmosphereReady = true
                    }
                    if showLyrics { showLyricsChromeTemporarily() }
                }
                .onDisappear {
                    Logger.ui.info("[PLAYER-VIEW] run=\(RuntimeDiagnostics.sessionID, privacy: .public) event=disappear")
                    atmosphereTask?.cancel()
                    atmosphereTask = nil
                    atmosphereReady = false
                    lyricsViewModel?.setVisible(false, owner: lyricsVisibilityOwner)
                    lyricsChromeAutoHideTask?.cancel()
                    lyricsChromeAutoHideTask = nil
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
            if let prepared = vm.themeColor(for: coverArtId, serverID: container?.serverState.activeServer?.id) { return prepared }
            let source = colorExtractor.colorOverride(for: coverArtId)
                ?? colorExtractor.cachedColor(for: coverArtId) ?? .black
            if source == .black || source == .clear { return .black }
            return CoverColorRefiner.playerAtmosphere(from: source).pageColor
        }()
        let isPlaying = playerState.playbackState.hasPlaybackIntent
        let showingQueue = isQueueVisible(playerState)

        surfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying,
                     showingQueue: showingQueue, backgroundColor: dominant)
            .overlay {
                #if os(iOS)
                if !usesWidePlayerLayout && !usesPhoneLandscape && dynamicTypeSize.isAccessibilitySize {
                    portraitFooter(playerState)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cassetteContentWidth(.fill)
            .cassetteDesktopPlayerFooter(enabled: {
                #if os(macOS)
                true
                #else
                usesWidePlayerLayout && !usesPhoneLandscape
                #endif
            }()) {
                sharedFooter(playerState)
            }
            .environment(\.marqueePaused, showLyrics || showingQueue || isRotating || scenePhase != .active)
            .environment(\.cassettePlayingAccent, CassetteColors.accentForeground(on: dominant))
        .background {
            // This opaque backing and Metal view survive surface changes. The
            // presentation must never expose the tab below between two surfaces.
            ZStack {
                Color.black
                AppleMusicLyricsBackground(
                    coverImage: playerCoverImage(for: coverArtId), fallbackColor: dominant,
                    isPlaying: playerState.playbackState == .playing,
                    animated: animatedArtwork && atmosphereReady && !showingQueue && !isRotating,
                    isPresented: !showsImmersivePlayer
                )
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func surfaceStack(_ playerState: PlayerState, coverArtId: String, isPlaying: Bool,
                              showingQueue: Bool, backgroundColor: Color) -> some View {
        #if os(iOS)
        if usesPhoneLandscape {
            phoneLandscapeSurface(playerState, coverArtId: coverArtId, showingQueue: showingQueue)
        } else if usesWidePlayerLayout {
            desktopSurfaceStack(playerState, coverArtId: coverArtId, isPlaying: isPlaying, showingQueue: showingQueue)
        } else if !dynamicTypeSize.isAccessibilitySize {
            portraitPlayer(playerState, coverArtId: coverArtId, backgroundColor: backgroundColor)
        } else {
        let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                flowGap((showLyrics || showingQueue) ? surfaceHeaderTopInset : playerTopInset)

                ZStack {
                    if let lyricsVM = lyricsViewModel {
                        flowingLyricsContent(
                            playerState,
                            lyricsVM: lyricsVM,
                            hideChrome: hideChrome
                        )
                        .opacity(showLyrics ? 1 : 0)
                        .allowsHitTesting(showLyrics)
                        .accessibilityHidden(!showLyrics)
                        .animation(.easeInOut(duration: 0.20), value: showLyrics)
                    }
                    if showingQueue {
                        flowingQueueContent(playerState)
                    }

                    flowingCover(
                        playerState,
                        coverArtId: coverArtId,
                        isSource: surface == .player,
                        isPlaying: isPlaying
                    )
                    .onTapGesture { toggleArtworkPlayback(playerState) }
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
                        .transition(.identity)
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
                        .padding(.top, showingQueue ? 0 : CassetteSpacing.xxxl + CassetteSpacing.xs)
                        .disabled(!playerState.isPlaybackAvailable || !playerState.isSeekable)
                        .opacity(playerState.isPlaybackAvailable && playerState.isSeekable ? 1.0 : 0.4)
                    }

                    if surface == .player || surface == .lyrics || surface == .queue {
                        PlaybackControlsView(
                            playerState: playerState,
                            playerService: container?.playerService,
                            isPlaybackAvailable: playerState.isPlaybackAvailable,
                            contentColor: vm.contentColor,
                            secondaryContentColor: vm.secondaryContentColor,
                            phonePortraitControls: true
                        )
                        .padding(.top, Self.playerControlsSpacing)

                        if dynamicTypeSize < .accessibility1 {
                            VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                                .padding(.horizontal, CassetteSpacing.xxl)
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

            // Reserve content space; the single toolbar lives above all three
            // surfaces and therefore never changes identity or layout on selection.
            Color.clear.frame(height: ImmersivePlayerMetrics.flowingFooterReservation)
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

    #if os(iOS)
    /// Player, lyrics and queue share this entire hierarchy. Only upper content
    /// visibility changes; the seek/transport/volume/output views stay mounted.
    private func portraitPlayer(_ state: PlayerState, coverArtId: String, backgroundColor: Color) -> some View {
        GeometryReader { geometry in
            let top = geometry.safeAreaInsets.top
            let bottom = geometry.safeAreaInsets.bottom
            let size = CGSize(width: geometry.size.width, height: geometry.size.height + top + bottom)
            let metrics = ImmersivePlayerMetrics(size: size, topInset: top, bottomInset: bottom)
            let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
            ImmersivePlayerControlsLayout(topInset: top, bottomInset: bottom, expandedPanel: hideChrome,
                showsStandardArtwork: !immersiveArtwork && surface == .player) {
                TrackInfoSection(
                    playerState: state, container: container,
                    contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.artist,
                    glassTint: vm.glassTint, layout: .immersivePortrait,
                    showsFavoriteStar: true, lyricsViewModel: lyricsViewModel
                )
                .opacity(surface == .player ? 1 : 0)
                .allowsHitTesting(surface == .player)
                .accessibilityHidden(surface != .player)
                ZStack {
                    if !state.isLiveStream {
                        ScrubberView(playerState: state, playerService: container?.playerService,
                            contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.timing,
                            isExpensiveNetwork: container?.serverState.isExpensive ?? false, immersivePortrait: true)
                            .disabled(!state.isPlaybackAvailable || !state.isSeekable)
                            .opacity(state.isPlaybackAvailable && state.isSeekable ? 1 : 0.4)
                    }
                }
                .opacity(hideChrome ? 0 : 1).allowsHitTesting(!hideChrome).accessibilityHidden(hideChrome)
                PlaybackControlsView(playerState: state, playerService: container?.playerService,
                    isPlaybackAvailable: state.isPlaybackAvailable, contentColor: ImmersivePlayerInk.primary,
                    secondaryContentColor: ImmersivePlayerInk.controls, spreadsTransport: true, phonePortraitControls: true)
                    .opacity(hideChrome ? 0 : 1).allowsHitTesting(!hideChrome).accessibilityHidden(hideChrome)
                VolumeSection(contentColor: ImmersivePlayerInk.controls, secondaryContentColor: ImmersivePlayerInk.controls)
                    .opacity(hideChrome ? 0 : 1).allowsHitTesting(!hideChrome).accessibilityHidden(hideChrome)
                BottomToolbar(surface: $surface, isLiveStream: state.isLiveStream,
                    lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                    lyricsViewModel: lyricsViewModel, translateEnabled: false,
                    contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.controls,
                    playerState: state, phonePortrait: true)
                    .opacity(hideChrome ? 0 : 1).allowsHitTesting(!hideChrome).accessibilityHidden(hideChrome)
                portraitPanels(state, coverArtId: coverArtId, hideChrome: hideChrome)
            }
            .frame(width: size.width, height: size.height)
            .background {
                ImmersiveNowPlayingBackground(coverArtId: coverArtId,
                    initialImage: playerCoverImage(for: coverArtId), fallbackColor: backgroundColor,
                    metrics: metrics,
                    lowerEdgeRGB: container?.artworkImageCache.preparedPalette(for: coverArtId)?.edgeAnalysis?.packedBottomBackground)
                    .opacity(showsImmersivePlayer ? 1 : 0)
            }
            .offset(y: -top)
        }
        .overlay(alignment: .top) { topBar.padding(.top, CassetteSpacing.xs) }
        .preferredColorScheme(.dark)
    }

    private func portraitPanels(_ state: PlayerState, coverArtId: String, hideChrome: Bool) -> some View {
        ZStack {
            if immersiveArtwork {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleArtworkPlayback(state) }
                    .allowsHitTesting(surface == .player)
                    .accessibilityHidden(true)
            }
            if !immersiveArtwork {
                StandardPlayerArtworkSlot(isPlaying: state.playbackState.hasPlaybackIntent,
                                          reduceMotion: reduceMotion) { side in
                    CoverArtCard(id: coverArtId, size: side, tier: .hero,
                                 cornerRadius: max(10, side * 0.038), initialImage: playerCoverImage(for: coverArtId))
                }
                .trackSkipSwipe(playerState: state)
                .onTapGesture { toggleArtworkPlayback(state) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleArtworkPlayback(state) }
                .opacity(surface == .player ? 1 : 0)
                .allowsHitTesting(surface == .player)
                .accessibilityHidden(surface != .player)
            }
            if let lyricsVM = lyricsViewModel {
                VStack(spacing: CassetteSpacing.s) {
                    portraitPanelHeader(state, coverArtId: coverArtId)
                    LyricsView(viewModel: lyricsVM, bottomChromeInset: CassetteSpacing.s,
                        fadesTopEdge: true, fadesBottomEdge: !hideChrome,
                        onInteraction: showLyricsChromeTemporarily, consumesLineTapToRevealChrome: hideChrome,
                        presentationIsVisible: showLyrics)
                        .id(lyricsVM.songId)
                        .animation(nil, value: surface)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottomTrailing) {
                            if !hideChrome, shouldShowLyricsTranslate(lyricsVM) {
                                CassetteLyricsTranslateButton(lyricsViewModel: lyricsVM,
                                    contentColor: ImmersivePlayerInk.primary,
                                    buttonSize: ImmersivePlayerMetrics.dismissTapHeight)
                                    .padding(CassetteSpacing.s)
                            }
                        }
                }
                .opacity(showLyrics ? 1 : 0)
                .allowsHitTesting(showLyrics)
                .accessibilityHidden(!showLyrics)
            }
            VStack(spacing: CassetteSpacing.s) {
                portraitPanelHeader(state, coverArtId: coverArtId)
                queuePills(state).padding(.horizontal, CassetteSpacing.l)
                InlineQueueList(playerState: state, contentColor: ImmersivePlayerInk.primary,
                    secondaryContentColor: ImmersivePlayerInk.artist, loadArtwork: isQueueVisible(state))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(surface == .queue ? 1 : 0)
            .allowsHitTesting(surface == .queue)
            .accessibilityHidden(surface != .queue)
        }
        // The square artwork slot must not cut off its animated drop shadow.
        .clipShape(Rectangle().inset(by: !immersiveArtwork && surface == .player ? -CassetteSpacing.xxxl : 0))
        .contentShape(Rectangle())
    }

    private func portraitPanelHeader(_ state: PlayerState, coverArtId: String) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtCard(id: coverArtId, size: ImmersivePlayerMetrics.panelHeaderSide, tier: .thumb,
                         initialImage: playerCoverImage(for: coverArtId))
                .frame(width: ImmersivePlayerMetrics.panelHeaderSide, height: ImmersivePlayerMetrics.panelHeaderSide)
                .onTapGesture { toggleArtworkPlayback(state) }
            TrackInfoSection(playerState: state, container: container,
                contentColor: ImmersivePlayerInk.primary, secondaryContentColor: ImmersivePlayerInk.artist,
                glassTint: vm.glassTint, layout: .lyricsHeader, showsTranslateBelowMenu: false,
                showsCoverThumbnail: false, showsFavoriteStar: true, lyricsViewModel: lyricsViewModel)
        }
        .padding(.leading, CassetteSpacing.xxxl)
        .padding(.trailing, 26)
        .frame(height: ImmersivePlayerMetrics.panelHeaderSide)
    }

    /// One stable overlay for player, lyrics and queue. Surface content can grow
    /// or collapse without moving the output picker, selection circles or labels.
    private func portraitFooter(_ state: PlayerState) -> some View {
        GeometryReader { geometry in
            let hideChrome = showLyrics && (lyricsViewModel?.prefersHiddenChrome == true)
            PortraitPlayerFooterLayout(topInset: geometry.safeAreaInsets.top,
                                       bottomInset: geometry.safeAreaInsets.bottom) {
                BottomToolbar(
                    surface: $surface, isLiveStream: state.isLiveStream,
                    lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                    lyricsViewModel: lyricsViewModel, translateEnabled: false,
                    contentColor: usesImmersivePortraitLayout ? ImmersivePlayerInk.primary : vm.contentColor,
                    secondaryContentColor: usesImmersivePortraitLayout ? ImmersivePlayerInk.controls : vm.secondaryContentColor,
                    playerState: state, phonePortrait: true
                )
                .opacity(hideChrome ? 0 : 1)
                .allowsHitTesting(!hideChrome)
                .accessibilityHidden(hideChrome)
                .animation(CassetteAnimation.chrome, value: hideChrome)
            }
        }
    }

    /// Keep the artwork in the same slot while the right column switches surfaces.
    private func phoneLandscapeSurface(_ state: PlayerState, coverArtId: String, showingQueue: Bool) -> some View {
        let hideChrome = showLyrics && lyricsViewModel?.prefersHiddenChrome == true
        let isPlaying = state.playbackState.hasPlaybackIntent
        return PhoneLandscapePlayerColumns {
            CoverArtView(id: coverArtId, size: ArtworkTier.hero.decodePixels, tier: .hero,
                         initialImage: playerCoverImage(for: coverArtId))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous))
                .modifier(PlayerArtworkPlaybackModifier(isPlaying: isPlaying, reduceMotion: reduceMotion))
                .trackSkipSwipe(playerState: state)
                .onTapGesture { toggleArtworkPlayback(state) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleArtworkPlayback(state) }
        } controls: {
            VStack(spacing: 8) {
                TrackInfoSection(
                    playerState: state, container: container,
                    contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                    glassTint: vm.glassTint, layout: .phoneLandscape, showLyrics: showLyrics,
                    showsTranslateBelowMenu: false, showsFavoriteStar: true,
                    lyricsViewModel: lyricsViewModel
                )
                .fixedSize(horizontal: false, vertical: true)
                if showLyrics {
                    desktopLyricsPanel(state)
                } else if showingQueue {
                    queuePills(state)
                    InlineQueueList(playerState: state, contentColor: vm.contentColor,
                                    secondaryContentColor: vm.secondaryContentColor, loadArtwork: true)
                        .environment(\.colorScheme, vm.isLightBackground ? .light : .dark)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            if !state.isLiveStream {
                                ScrubberView(playerState: state, playerService: container?.playerService,
                                             contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                                             isExpensiveNetwork: container?.serverState.isExpensive ?? false,
                                             phoneLandscape: true)
                                    .disabled(!state.isPlaybackAvailable || !state.isSeekable)
                            }
                            GeometryReader { controls in
                                PlaybackControlsView(playerState: state, playerService: container?.playerService,
                                                     isPlaybackAvailable: state.isPlaybackAvailable,
                                                     contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                                                     compactLayout: true, spreadsTransport: true)
                                    .padding(.horizontal, min(36, max(0, (controls.size.width - 176) / 2)))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .frame(height: 64)
                            VolumeSection(contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.bottom, showLyrics ? 0 : 104)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if !hideChrome {
                    BottomToolbar(surface: $surface, isLiveStream: state.isLiveStream,
                                  lyricsEnabled: lyricsViewModel?.isLyricsButtonEnabled ?? false,
                                  lyricsViewModel: lyricsViewModel,
                                  contentColor: vm.contentColor, secondaryContentColor: vm.secondaryContentColor,
                                  playerState: state, showsRouteName: true, phoneLandscape: true)
                        .overlay(alignment: .trailing) {
                            if showLyrics, let lyricsVM = lyricsViewModel, shouldShowLyricsTranslate(lyricsVM) {
                                CassetteLyricsTranslateButton(lyricsViewModel: lyricsVM, contentColor: vm.contentColor,
                                    buttonSize: ImmersivePlayerMetrics.dismissTapHeight)
                                    .padding(.trailing, (ImmersivePlayerMetrics.footerHeight - ImmersivePlayerMetrics.dismissTapHeight) / 2)
                                    .offset(y: -(ImmersivePlayerMetrics.footerHeight + ImmersivePlayerMetrics.landscapeTranslationGap))
                            }
                        }
                        .padding(.bottom, 55)
                }
            }
        }
        .overlay(alignment: .top) { topBar.padding(.top, 27) }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
    #endif

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

                CoverArtView(id: coverArtId, size: 700, initialImage: playerCoverImage(for: coverArtId))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                    .scaleEffect(isPlaying ? 1.0 : 0.92)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)
                    .trackSkipSwipe(playerState: playerState)
                    .onTapGesture { toggleArtworkPlayback(playerState) }

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
                LyricsView(viewModel: lyricsVM, density: .spacious,
                    usesMeasuredScrollAnchor: usesPhoneLandscape,
                    phoneLandscape: usesPhoneLandscape,
                    // Lyrics continue behind the toolbar; only the active-row anchor
                    // reserves the overlaid controls, without shrinking the viewport.
                    bottomChromeInset: usesPhoneLandscape && !lyricsVM.prefersHiddenChrome ? 104 : 0,
                    fadesTopEdge: true,
                    fadesBottomEdge: !lyricsVM.prefersHiddenChrome,
                    onInteraction: showLyricsChromeTemporarily,
                    consumesLineTapToRevealChrome: lyricsVM.prefersHiddenChrome,
                    presentationIsVisible: showLyrics)
                    .id(lyricsVM.songId)
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
        .padding(.trailing, usesPhoneLandscape ? 0 : CassetteSpacing.l)
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
        if lyricsViewModel?.prefersHiddenChrome == true {
            withAnimation(CassetteAnimation.chrome) {
                lyricsViewModel?.prefersHiddenChrome = false
            }
        }
        lyricsChromeAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, surface == .lyrics else { return }
            guard scenePhase == .active else { return }
            withAnimation(reduceMotion ? nil : CassetteAnimation.chrome) {
                lyricsViewModel?.prefersHiddenChrome = true
            }
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

            CoverArtView(id: coverArtId, size: 600, initialImage: playerCoverImage(for: coverArtId), contentMode: .fill)
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
                .transition(.identity)
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.xs)
            .padding(.bottom, CassetteSpacing.s)

            LyricsView(
                viewModel: lyricsVM,
                bottomChromeInset: hideChrome ? 20 : 8,
                fadesBottomEdge: !hideChrome,
                onInteraction: showLyricsChromeTemporarily,
                consumesLineTapToRevealChrome: hideChrome,
                presentationIsVisible: showLyrics
            )
            // Layout/matched artwork animate at the surface level; rebuilding every word's
            // masks and measurements inside that transaction makes the transition hitch.
            .animation(nil, value: surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .overlay(alignment: .bottomTrailing) {
                if !hideChrome, shouldShowLyricsTranslate(lyricsVM) {
                    CassetteLyricsTranslateButton(
                        lyricsViewModel: lyricsVM,
                        contentColor: vm.contentColor,
                        buttonSize: 46,
                        iconSize: 16
                    )
                    .padding(.trailing, CassetteSpacing.m)
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
        let hideChrome = showLyrics && lyricsViewModel?.prefersHiddenChrome == true
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
        .opacity(hideChrome ? 0 : 1)
        .allowsHitTesting(!hideChrome)
        .accessibilityHidden(hideChrome)
    }

    private var topBar: some View {
        PlayerDismissHandle(contentColor: usesImmersivePortraitLayout ? ImmersivePlayerInk.primary : vm.contentColor,
                            action: closePlayer)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
    }

    private func toggleArtworkPlayback(_ state: PlayerState) {
        guard state.isPlaybackAvailable else { return }
        Task { await container?.playerService.togglePlayPause() }
    }

    private func closePlayer() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
