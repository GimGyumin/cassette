// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct PlaylistDetailView: View {
    let playlistId: String
    let initialName: String
    let coverArtId: String?
    private let initialDominantColor: Color
    let initialCoverImage: PlatformImage?
    private let zoomSourceId: String?
    private let zoomNamespace: Namespace.ID?

    init(playlist: Playlist, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        playlistId = playlist.id
        initialName = playlist.name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlist.id
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    init(playlist: DownloadedPlaylist, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        playlistId = playlist.playlistId
        initialName = playlist.name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlist.playlistId
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    init(playlistId: String, name: String, coverArtId: String? = nil, initialDominantColor: Color = .clear, initialCoverImage: PlatformImage? = nil, zoomSourceId: String? = nil, zoomNamespace: Namespace.ID? = nil) {
        self.playlistId = playlistId
        self.initialName = name
        self.coverArtId = coverArtId
        self.initialDominantColor = initialDominantColor
        self.initialCoverImage = initialCoverImage
        self.zoomSourceId = zoomSourceId
        self.zoomNamespace = zoomNamespace
        let pid = playlistId
        _downloadedPlaylistMatches = Query(filter: #Predicate<DownloadedPlaylist> { $0.playlistId == pid })
        _dominantColor = State(initialValue: initialDominantColor)
    }

    @Environment(\.appContainer) var container
    @Environment(\.dismiss) var dismiss
    @Environment(DominantColorExtractor.self) var colorExtractor
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesDesktopDetail: Bool {
        CassetteWideLayout.usesDesktopDetail(horizontalSizeClass: horizontalSizeClass)
    }
    @State var viewModel: PlaylistDetailViewModel?
    @State var dominantColor: Color = .clear
    /// A user-picked gradient spec (if any) -> the hero renders CRISP from it instead of the JPEG. Resolved
    /// from PlaylistCoverStore on appear + after an edit (coverRefreshID). Nil for photo / server cover.
    @State var gradientSpec: PlaylistGradientSpec?
    @State var showDeleteAlert = false
    @State var showAddMusic = false
    @State var songToAddToPlaylist: DisplayableSong?

    @State var coverRefreshID = UUID()

    // MARK: In-place edit mode (iOS only — macOS keeps EditPlaylistSheet). The detail view becomes the editor:
    // hero → editable cover carousel, title/description → fields, track list (Gate 2) → reorder + multi-select.
    // Reuses the validated PlaylistCoverCarousel + the mutation committer — only the CONTAINER changes.
    @State var isEditing = false
    @State var editName: String = ""
    @State var editComment: String = ""
    @State var editIsPublic = false
    /// Local mutable working copy of the track list — reorder (drag) + multi-select remove both mutate this;
    /// the commit does ONE atomic full-list replace (Gate 3) if it differs from the loaded songs.
    @State var editSongs: [DisplayableSong] = []
    @State var selectedSongIds: Set<String> = []
    @State var selectedGradient: PlaylistGradientShape?
    @State var photoIsCover = false
    @State var coverDirty = false
    @State var showDeletePlaylistConfirm = false
    @State var showRemoveSongsConfirm = false
    @State var showPinLimitAlert = false
    @State var isSaving = false
    #if os(iOS)
    @State var pendingImage: UIImage?
    @State var showImageOptions = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State var imageToCrop: CroppableImage?
    #endif

    // Immersive hero geometry (captured from the view; tunable). `heroHeight` = the cover region height; the
    // cover lives in the first SCROLLING row and bleeds under the nav bar via ignoresSafeArea.
    @State var heroHeight: CGFloat = 680

    // View-level offline backstop: sources the song list straight from SwiftData when the
    // view model produced nothing (empty-success or error). Mirrors AlbumDetailView's
    // downloaded fallback so a downloaded playlist stays readable independent of the
    // network, the VM, and connectivity detection. Keyed on playlistId here; serverId is
    // applied at read time since it isn't known at init.
    @Query private var downloadedPlaylistMatches: [DownloadedPlaylist]
    @Query private var allDownloadedTracks: [DownloadedTrack]


    /// The cover id actually displayed: the server cover, else the playlist id — under which a generated
    /// gradient cover is cached (`{playlistId}@{tier}`). Drives BOTH the cover and the theme derivation, so a
    /// gradient playlist (which has no server `coverArt`) is themed from its gradient, not left unthemed.
    var effectiveCoverArtId: String { viewModel?.coverArtId ?? coverArtId ?? playlistId }

    /// Cover extract → refined Apple Music atmosphere (gradient page + adaptive chrome).
    var atmosphere: AlbumAtmosphere {
        AlbumAtmosphere.from(
            dominantColor: dominantColor,
            appearance: AlbumAtmosphere.appearance(
                colorScheme: colorScheme,
                increaseContrast: colorSchemeContrast == .increased
            )
        )
    }
    var theme: PlaylistTheme { atmosphere.heroTheme }
    var headerTextColor: Color { atmosphere.contentColor }
    var headerSecondaryColor: Color { atmosphere.secondaryContentColor }

    /// Solid row fill (list occludes the gradient). Uses refined page tone.
    var bodyColor: Color {
        if atmosphere.isThemed { return atmosphere.pageColor }
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// Header metadata line, Apple-Music style: "N songs · Updated <relative date>".
    func metadataLine(count: Int, updated: Date?) -> String {
        var parts = [CassetteCountLabel.songs(count)]
        if let updated {
            parts.append("Updated \(updated.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
    private var heroIconColor: Color {
        CassetteColors.accentForeground(on: dominantColor == .clear ? bodyColor : dominantColor)
    }
    /// Unified (background, glyph/label) for every hero over-cover button — B/W fill with cover-tinted label.
    var heroButtonVariant: (background: Color, foreground: Color) {
        // Foreground is contrast-driven black/white only — never the page/cover tint.
        CassetteColors.heroButtonVariant(on: dominantColor, labelTint: nil)
    }
    var isLoadingSkeleton: Bool {
        viewModel == nil || (viewModel?.isLoading == true && viewModel?.songs.isEmpty == true)
    }

    /// Downloaded tracks reconstructed from SwiftData in playlist order, independent of the
    /// view model. Used as the offline backstop when `viewModel.songs` is empty.
    private var downloadedFallbackSongs: [DisplayableSong] {
        guard let serverId = container?.serverState.activeServer?.id,
              let record = downloadedPlaylistMatches.first(where: { $0.serverId == serverId })
        else { return [] }
        let bySongId = Dictionary(
            allDownloadedTracks.filter { $0.serverId == serverId }.map { ($0.songId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return record.songIds.compactMap { bySongId[$0] }.map { DisplayableSong(from: $0) }
    }

    /// Prefer the view model's list; fall back to the downloaded copy when it is empty.
    func resolvedSongs(_ vm: PlaylistDetailViewModel?) -> [DisplayableSong] {
        if let songs = vm?.songs, !songs.isEmpty { return songs }
        return downloadedFallbackSongs
    }

    var body: some View {
        Group {
            if usesDesktopDetail {
                desktopPlaylistBody
            } else {
                compactPlaylistBody
            }
        }
        #if os(iOS)
        // Edit mode ONLY while editing — nil otherwise. Forcing an editMode binding (even .inactive) in view
        // mode broke the List's scrolling; nil restores the default (normal scroll) for the read-only view.
        .environment(\.editMode, isEditing ? Binding.constant(EditMode.active) : nil)
        #endif
        .cassetteHideTopScrollEdgeEffect()
        .cassetteStatusBarScrim(isLightPage: atmosphere.isLight)
        .miniPlayerBottomMargin()
        .refreshable { await viewModel?.load() }
        .cassetteDestructiveAlert(
            "Remove downloaded playlist?",
            isPresented: $showDeleteAlert,
            message: "The audio files will be deleted from this device."
        ) {
            Task { await viewModel?.deleteDownload() }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
        }
        #if os(iOS)
        // In-place edit cover photo flow (mirrors the create/edit sheets: pick → Apple-Photos crop).
        .confirmationDialog("Cover Art", isPresented: $showImageOptions, titleVisibility: .visible) {
            Button("Choose from Library") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showImagePicker = true }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take a Photo") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showCamera = true }
                }
            }
            Button("Browse Files") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showFilePicker = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showImagePicker) {
            ImagePickerController(sourceType: .photoLibrary, allowsEditing: false, onPick: { presentCrop($0) }, onCancel: {})
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePickerController(sourceType: .camera, allowsEditing: false, onPick: { presentCrop($0) }, onCancel: {})
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $imageToCrop) { croppable in
            SquareCropView(image: croppable.image, onCrop: { pendingImage = $0; imageToCrop = nil }, onCancel: { imageToCrop = nil })
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.jpeg, .png, .heic, .webP], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { presentCrop(img) }
        }
        #endif
        .deletePlaylistConfirmation(
            playlistName: viewModel?.name ?? initialName,
            isPresented: $showDeletePlaylistConfirm,
            hasDownloads: (viewModel?.songs.contains { $0.isDownloaded } ?? false) || !downloadedPlaylistMatches.isEmpty
        ) { purgeDownloads in
            Task { await deletePlaylistInPlace(purgeDownloads: purgeDownloads) }
        }
        .alert(String(localized: "Pin Limit Reached", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isPresented: $showPinLimitAlert) {
            Button(String(localized: "OK", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
        .cassetteDestructiveAlert(
            CassetteCountLabel.removeSongsConfirm(selectedSongIds.count),
            isPresented: $showRemoveSongsConfirm,
            message: String(localized: "They'll be removed from the playlist when you save.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            removeSelectedTracks()
        }
        .sheet(isPresented: $showAddMusic) {
            if let vm = viewModel, let c = container, let serverId = c.serverState.activeServer?.id {
                AddMusicSheet(
                    playlistName: vm.name,
                    existingTrackIds: resolvedSongs(vm).map(\.id)
                ) { added in
                    await AddMusicCommitter.commit(
                        addedSongs: added,
                        playlistId: playlistId,
                        serverId: serverId,
                        existingTrackIds: resolvedSongs(vm).map(\.id),
                        currentComment: vm.playlistDetail?.comment ?? "",
                        container: c,
                        colorExtractor: colorExtractor
                    )
                    await vm.load()
                    coverRefreshID = UUID()
                }
                .environment(colorExtractor)
                .environment(c.artworkImageCache)
                .environment(\.appContainer, c)
            }
        }
        .background {
            CoverAtmosphereBackground(
                top: atmosphere.gradientTop,
                mid: atmosphere.gradientMid,
                bottom: atmosphere.gradientBottom,
                isThemed: atmosphere.isThemed,
                isLight: atmosphere.isLight
            )
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        if !usesDesktopDetail { heroHeight = proxy.size.width }
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        if !usesDesktopDetail { heroHeight = w }
                    }
            }
        }
        .cassetteContentWidth()
        .environment(\.cassettePlayingAccent, heroIconColor)
        .environment(\.colorScheme, atmosphere.preferredColorScheme ?? colorScheme)
        .chromeAppearance(atmosphere.preferredColorScheme)
        .navigationTitle("")
        .navigationBarTitleDisplayModeInline()
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .enableSwipeBack()
        #endif
        .toolbar { toolbarContent }
        // Transparent nav bar so the cover floats under it; adapt status-bar style to cover
        // lightness (black icons on a light cover — toolbarColorScheme alone is ignored when hidden).
        #if os(iOS)
        .cassetteImmersiveStatusBar(colorScheme: atmosphere.preferredColorScheme)
        #endif
        // Keyed on connectivity so the list re-loads from the right source when
        // NWPathMonitor flips isOnline — same pattern as PlaylistDetailMacOS.
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = PlaylistDetailViewModel(
                    playlistId: playlistId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    playlistService: c.playlistService,
                    toastService: c.toastService,
                    serverState: c.serverState
                )
            }
            await viewModel?.load()
        }
        .task(id: effectiveCoverArtId) {
            // Photo / server cover -> extract the dominant. Gradient playlists are themed from the spec base
            // color (cover-refresh task), not the JPEG, so gradient + body stay coherent.
            guard gradientSpec == nil else { return }
            let artId = effectiveCoverArtId
            let cached = colorExtractor.dominantColor(for: artId, image: nil)
            if cached != .clear {
                dominantColor = cached
                return
            }
            await loadDominantColor(coverArtId: artId)
        }
        .task(id: coverRefreshID) {
            // A user-picked gradient -> render the hero CRISP from the spec (the JPEG stays the
            // cards/cross-device truth), AND theme the body straight from the (vibrance-boosted) spec base
            // color so gradient + background + body stay coherent, no JPEG re-extraction. Re-resolves after an
            // edit (coverRefreshID bumps). Nil -> JPEG/photo path keeps the extractor.
            guard let container, let serverId = container.serverState.activeServer?.id else { gradientSpec = nil; return }
            let choice = PlaylistCoverStore(modelContainer: container.modelContainer).choice(playlistId: playlistId, serverId: serverId)
            let spec = choice?.isUserPicked == true ? choice?.spec : nil
            gradientSpec = spec
            if let spec {
                withAnimation(CassetteAnimation.theme) { dominantColor = spec.baseColor }
            }
        }
        .cassetteZoomTransition(sourceID: zoomSourceId, in: zoomNamespace)
    }

}
