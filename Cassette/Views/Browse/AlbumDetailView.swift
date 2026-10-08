// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Mode

struct AlbumShelfBackgroundKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

enum AlbumDetailMode: Sendable {
    case full           // show all album songs (default — online catalog browsing)
    case downloadedOnly // show only downloaded tracks (Downloads/Offline contexts for purely-partial albums)
}

/// Resolves an already-visible album cover into a page theme before the detail view's
/// first frame is built. Album grids/lists normally have the thumbnail in RAM by the
/// time navigation starts; using it here keeps the toolbar and root mini-player from
/// briefly retaining the previous page's light/dark appearance.
struct AlbumDetailView: View {
    private enum Source {
        case album(AlbumID3)
        case identifier(id: String, name: String)
    }

    private let source: Source
    private let zoomSourceId: String?
    private let zoomNamespace: Namespace.ID?
    private let coverArtId: String?
    private let suppliedDominantColor: Color
    private let suppliedCoverImage: PlatformImage?
    private let mode: AlbumDetailMode

    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(ArtworkImageCache.self) private var artworkImageCache

    init(
        album: AlbumID3,
        zoomSourceId: String? = nil,
        zoomNamespace: Namespace.ID? = nil,
        coverArtId: String? = nil,
        initialDominantColor: Color = .clear,
        initialCoverImage: PlatformImage? = nil,
        mode: AlbumDetailMode = .full
    ) {
        source = .album(album)
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.coverArtId = coverArtId ?? album.coverArt
        suppliedDominantColor = initialDominantColor
        suppliedCoverImage = initialCoverImage
        self.mode = mode
    }

    init(
        albumId: String,
        albumName: String,
        zoomSourceId: String? = nil,
        zoomNamespace: Namespace.ID? = nil,
        coverArtId: String? = nil,
        initialDominantColor: Color = .clear,
        initialCoverImage: PlatformImage? = nil,
        mode: AlbumDetailMode = .full
    ) {
        source = .identifier(id: albumId, name: albumName)
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.coverArtId = coverArtId
        suppliedDominantColor = initialDominantColor
        suppliedCoverImage = initialCoverImage
        self.mode = mode
    }

    var body: some View {
        let themeKey = coverArtId ?? resolvedAlbumID
        // Prefer the exact image supplied by the source card, then the thumbnail that
        // was just painted in the list. No network or disk work is started from body.
        let preparedImage = suppliedCoverImage
            ?? artworkImageCache.cachedImage(for: themeKey, tier: .thumb)
            ?? artworkImageCache.cachedImage(for: themeKey, tier: .hero)
        let preparedColor = immediateThemeColor(key: themeKey)

        Group {
            if let album = resolvedAlbum {
                AlbumDetailContentView(
                    album: album,
                    zoomSourceId: zoomSourceId,
                    zoomNamespace: zoomNamespace,
                    coverArtId: coverArtId,
                    initialDominantColor: preparedColor,
                    initialCoverImage: preparedImage,
                    mode: mode
                )
            } else {
                AlbumDetailContentView(
                    albumId: resolvedAlbumID,
                    albumName: resolvedAlbumName,
                    zoomSourceId: zoomSourceId,
                    zoomNamespace: zoomNamespace,
                    coverArtId: coverArtId,
                    initialDominantColor: preparedColor,
                    initialCoverImage: preparedImage,
                    mode: mode
                )
            }
        }
    }

    private var resolvedAlbum: AlbumID3? {
        guard case let .album(album) = source else { return nil }
        return album
    }

    private var resolvedAlbumID: String {
        switch source {
        case let .album(album): album.id
        case let .identifier(id, _): id
        }
    }

    private var resolvedAlbumName: String {
        switch source {
        case let .album(album): album.name
        case let .identifier(_, name): name
        }
    }

    private func immediateThemeColor(key: String) -> Color {
        if let override = colorExtractor.colorOverride(for: key) { return override }
        if let cached = ColorCache.palette(for: key)?.background { return cached }
        if suppliedDominantColor != .clear { return suppliedDominantColor }
        if let cached = colorExtractor.cachedColor(for: key) { return cached }
        // A cold image can require decoding and palette clustering. The page's task
        // performs that work off-main; body must remain a cache-only lookup.
        return .clear
    }
}

struct AlbumDetailContentView: View {
    let albumId: String
    let initialName: String
    let coverArtId: String?
    private let initialDominantColor: Color
    private let initialCoverImage: PlatformImage?
    private let zoomSourceId: String?
    private let zoomNamespace: Namespace.ID?
    let mode: AlbumDetailMode

    init(album: AlbumID3, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, mode: AlbumDetailMode = .full) {
        albumId = album.id
        initialName = album.name
        let resolvedCoverArtId = coverArtId ?? album.coverArt
        let cachedColor = ColorCache.palette(for: resolvedCoverArtId ?? album.id)?.background ?? .clear
        let resolvedInitialColor = initialDominantColor == .clear ? cachedColor : initialDominantColor
        self.coverArtId = resolvedCoverArtId
        self.initialDominantColor = resolvedInitialColor
        self.initialCoverImage = initialCoverImage
        let itemId = album.id
        let type = FavoriteType.album.rawValue
        let aid = album.id
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.mode = mode
        _dominantColor = State(initialValue: resolvedInitialColor)
    }

    init(albumId: String, albumName: String, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, mode: AlbumDetailMode = .full) {
        self.albumId = albumId
        self.initialName = albumName
        self.coverArtId = coverArtId
        let cachedColor = ColorCache.palette(for: coverArtId ?? albumId)?.background ?? .clear
        let resolvedInitialColor = initialDominantColor == .clear ? cachedColor : initialDominantColor
        self.initialDominantColor = resolvedInitialColor
        self.initialCoverImage = initialCoverImage
        let itemId = albumId
        let type = FavoriteType.album.rawValue
        let aid = albumId
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
        _downloadedAlbumTracks = Query(filter: #Predicate<DownloadedTrack> { $0.albumId == aid })
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        self.mode = mode
        _dominantColor = State(initialValue: resolvedInitialColor)
    }

    @Environment(\.appContainer) var container
    @Environment(\.dismiss) private var dismiss
    @Environment(DominantColorExtractor.self) var colorExtractor
    @Environment(ArtworkImageCache.self) var artworkImageCache
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State var viewModel: AlbumDetailViewModel?
    @State var dominantColor: Color = .clear
    /// Seed for the first frame only; the real value comes from the container's width on the first
    /// layout pass below. Deliberately *not* derived from `UIScreen.main`: on iPad (and in Split
    /// View / Slide Over) the screen is far wider than this view's column, which produced a hero up
    /// to ~1250 pt tall for one frame before the geometry corrected it.
    @State var heroHeight: CGFloat = 310
    @State var showDeleteAlert = false
    @State var songToAddToPlaylist: DisplayableSong?
    @State var showDescriptionSheet = false
    @State var showPinLimitAlert = false
    /// Compact scroll: 0 at top → 1 after ~heroHeight for nav bar material.
    @State var navChromeProgress: CGFloat = 0
    /// Identity for the artist pushed from this album page's header. `HomeDestination` artist values are
    /// equal by content, and `NavigationStack` reuses the entry holding an equal value — an artist page
    /// reached *from* this album must still push a fresh entry (otherwise the stack pops to an earlier
    /// artist page and the back button points at a removed entry). One token per album page instance.
    @State var artistRouteToken = UUID()
    /// Stable, page-local identity for albums pushed from the related releases shelves.
    /// A detail-to-detail path must not depend on a refreshed AlbumID3 payload.
    @State var albumRouteToken = UUID()
    /// Identity of this page instance. `album → artist → back` regressions have twice been a page in
    /// the stack being destroyed and re-created; one log line per instance makes that visible instead
    /// of guessed at (the fixes themselves live in the navigation structure).
    @State private var pageInstanceID = UUID()
    /// The `isOnline` value this page already loaded for. A `.task` restart that carries the same
    /// value — the page was rebuilt, or SwiftUI re-applied the same id — must not re-run the whole
    /// album + More-By + description load behind whatever page is open on top of this one.
    @State private var loadedForOnlineState: Bool?
    @Query private var albumFavoriteMatches: [FavoriteRecord]
    @Query var downloadedAlbumTracks: [DownloadedTrack]

    var usesDesktopDetail: Bool {
        CassetteWideLayout.usesDesktopDetail(horizontalSizeClass: horizontalSizeClass)
    }

    var isAlbumFavorite: Bool {
        guard let serverId = container?.serverState.activeServer?.id else { return false }
        return albumFavoriteMatches.contains { $0.serverId == serverId }
    }
    var downloadedCount: Int { downloadedAlbumTracks.count }
    var isOnline: Bool { container?.serverState.isOnline == true }
    /// Cover id the album theme is keyed on.
    var albumCoverId: String { viewModel?.coverArtId ?? coverArtId ?? albumId }
    var isLoadingSkeleton: Bool {
        viewModel == nil || (viewModel?.isLoading == true && viewModel?.songs.isEmpty == true)
    }
    /// Music.app keeps white ink on medium-bright chromatic album pages. Reserve black
    /// ink for genuinely near-white artwork where white would disappear.
    private var usesWhiteAlbumInk: Bool {
        atmosphere.isThemed && atmosphere.pageColor.luminance < 0.72
    }
    private var albumChromeColorScheme: ColorScheme? {
        guard atmosphere.isThemed else { return nil }
        return usesWhiteAlbumInk ? .dark : .light
    }
    var headerTextColor: Color {
        return atmosphere.isThemed ? (usesWhiteAlbumInk ? .white : .black) : .primary
    }
    var headerSecondaryColor: Color {
        return atmosphere.isThemed
            ? (usesWhiteAlbumInk ? Color.white.opacity(0.80) : Color.black.opacity(0.72))
            : .secondary
    }
    /// Title + artist name render as pure white/black ink over the floating cover, like
    /// Apple Music's high-contrast presentation — independent of the cover tint.
    var heroTitleInk: Color {
        headerTextColor
    }
    /// Contrast-aware accent for the now-playing row (bars + title).
    private var heroIconColor: Color {
        if atmosphere.isThemed { return headerTextColor }
        return CassetteColors.accentForeground(on: systemBackgroundColor)
    }
    /// Play CTA: black/white fill; label uses cover color when contrast allows.
    var heroButtonVariant: (background: Color, foreground: Color) {
        if atmosphere.isThemed, usesWhiteAlbumInk {
            return (
                background: .white,
                foreground: CoverColorRefiner.playerAtmosphere(from: dominantColor).pageColor
            )
        }
        return CassetteColors.heroButtonVariant(on: dominantColor, labelTint: nil)
    }
    var atmosphere: AlbumAtmosphere {
        AlbumAtmosphere.from(
            dominantColor: dominantColor,
            colorScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        )
    }
    var theme: PlaylistTheme { atmosphere.heroTheme }
    /// Bottom shelves (“Other versions” / “More by”) own the mini-player inset fill.
    private var showsMoreByShelf: Bool {
        guard mode == .full, let vm = viewModel, !displaySongs().isEmpty else { return false }
        guard vm.artistId != nil else { return false }
        return !vm.otherAlbumVersions.isEmpty
            || !vm.moreAlbumsByArtist.isEmpty
            || vm.isLoadingMoreAlbums
    }
    private var systemBackgroundColor: Color {
        #if canImport(UIKit)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var effectiveInitialImage: PlatformImage? {
        initialCoverImage ?? artworkImageCache.cachedImage(for: coverArtId ?? albumId)
    }

    // MARK: - Song filtering

    private var offlineFallbackSongs: [DisplayableSong] {
        downloadedAlbumTracks
            .map { DisplayableSong(from: $0) }
            .sorted(by: AlbumDetailViewModel.albumTrackOrder)
    }

    private func filteredSongs(_ vmSongs: [DisplayableSong]) -> [DisplayableSong] {
        switch mode {
        case .full:
            return vmSongs
        case .downloadedOnly:
            let downloadedIds = Set(downloadedAlbumTracks.map(\.songId))
            return vmSongs.filter { downloadedIds.contains($0.id) }
        }
    }

    func displaySongs() -> [DisplayableSong] {
        switch mode {
        case .downloadedOnly:
            if let vm = viewModel, vm.error == nil, !vm.songs.isEmpty {
                return filteredSongs(vm.songs)
            }
            return offlineFallbackSongs
        case .full:
            // Prefer the VM's catalog list, but back-stop with downloaded tracks whenever
            // the VM produced nothing — whether it errored OR returned an empty-success
            // payload (captive proxy / Cloudflare-WARP). This is the view-level safety net
            // that keeps a downloaded album readable through normal nav, not just Downloads.
            if let vm = viewModel, !vm.songs.isEmpty {
                return vm.songs
            }
            return offlineFallbackSongs
        }
    }

    var body: some View {
        Group {
            if usesDesktopDetail {
                desktopAlbumBody
            } else {
                compactAlbumBody
            }
        }
        .refreshable { await viewModel?.load() }
        // More by reserves its own bottom inset; otherwise use the shared margin.
        .modifier(AlbumMiniPlayerMargin(enabled: !showsMoreByShelf))
        // Music's album artwork begins below the navigation controls. Full-bleed is
        // reserved for artist imagery; applying it here pulls the cover under the bar.
        .modifier(AlbumTopBleedModifier(bleed: false))
        .cassetteHideTopScrollEdgeEffect()
        .cassetteStatusBarScrim(isLightPage: albumChromeColorScheme == .light)
        .cassetteDestructiveAlert(
            "Remove downloaded album?",
            isPresented: $showDeleteAlert,
            message: "The audio files will be deleted from this device."
        ) {
            Task { await viewModel?.deleteDownload() }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showDescriptionSheet) {
            let description = viewModel?.albumDescription ?? ""
            NavigationStack {
                ScrollView {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle(String(localized: "About", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .navigationBarTitleDisplayModeInline()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { showDescriptionSheet = false }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        .background {
            AlbumAtmosphereBackground(atmosphere: atmosphere)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        if !usesDesktopDetail { heroHeight = max(180, proxy.size.width - 136) }
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        if !usesDesktopDetail { heroHeight = max(180, w - 136) }
                    }
            }
        }
        .cassetteContentWidth()
        .environment(\.cassettePlayingAccent, heroIconColor)
        .environment(\.colorScheme, albumChromeColorScheme ?? colorScheme)
        .chromeAppearance(albumChromeColorScheme)
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        #if os(iOS)
        .navigationBarBackButtonHidden(false)
        .toolbarColorScheme(albumChromeColorScheme, for: .navigationBar)
        #else
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(headerTextColor)
                        .cassetteHeroButton(size: 34)
                }
                .buttonStyle(.plain)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: CassetteSpacing.xs) {
                    CassetteShareButtonWithOptions(
                        itemID: albumId,
                        shareOptions: ShareSettings.shared.makeAlbumOptions(albumName: albumDisplayName),
                        fallbackText: albumShareText,
                        style: .circle(foreground: headerTextColor)
                    )
                    .buttonStyle(.plain)

                    albumMoreMenu
                }
            }
        }
        .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
        #if os(iOS)
        .cassetteImmersiveStatusBar(
            colorScheme: albumChromeColorScheme,
            scrolledChromeProgress: navChromeProgress
        )
        #endif
        // Keyed on connectivity so the list re-loads from the right source when
        // NWPathMonitor flips isOnline — same pattern as AlbumDetailMacOS and
        // PlaylistDetailView. Guarded by the connectivity state actually loaded, so an id change that
        // carries no new value cannot re-run the whole load (see `loadedForOnlineState`).
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = AlbumDetailViewModel(
                    albumId: albumId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    toastService: c.toastService,
                    serverState: c.serverState
                )
            }
            let isOnline = c.serverState.isOnline
            Logger.ui.debug(
                "[ALBUM-PAGE] task start instance=\(pageInstanceID, privacy: .public) album=\(albumId, privacy: .public) online=\(isOnline, privacy: .public) loaded=\(String(describing: loadedForOnlineState), privacy: .public)"
            )
            // SwiftUI restarts .task when a pushed page is uncovered. If optional album-info
            // work was cancelled after tracks appeared, preserve the completed primary load.
            if loadedForOnlineState == nil,
               viewModel?.isPrimaryContentReady == true,
               viewModel?.isOffline == !isOnline {
                loadedForOnlineState = isOnline
            }
            guard loadedForOnlineState != isOnline else { return }
            await viewModel?.load()
            if !Task.isCancelled, viewModel?.isPrimaryContentReady == true {
                loadedForOnlineState = isOnline
            }
        }
        .task(id: albumCoverId) {
            await resolveDominantColor(coverArtId: albumCoverId)
        }
        .onAppear {
            Logger.ui.debug("[NAV] album appear instance=\(pageInstanceID, privacy: .public) album=\(albumId, privacy: .public)")
        }
        .onDisappear {
            Logger.ui.debug("[NAV] album disappear instance=\(pageInstanceID, privacy: .public) album=\(albumId, privacy: .public)")
        }
        // Use the standard NavigationStack push so iOS owns the interactive edge pop from
        // every album entry point, including albums opened from an artist page.
    }

}
