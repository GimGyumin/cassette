// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftData
import SwiftSonic

struct ArtistDetailMacOS: View {
    let artistId: String
    let artistName: String
    let coverArtId: String?
    var showBackButton: Bool = true

    init(artistId: String, artistName: String, coverArtId: String? = nil, showBackButton: Bool = true) {
        self.artistId = artistId
        self.artistName = artistName
        self.coverArtId = coverArtId
        self.showBackButton = showBackButton
        let cid = "artist:\(artistId)"
        _artistFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
    }

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var vm: ArtistDetailViewModel?
    @State private var selectedOutOfLibraryArtist: SimilarArtistRecommendation?
    /// Shared album ordering, persisted and reused by the global album list too.
    @AppStorage("cassette.albumSort") private var albumSort: AlbumSort = .recentlyAdded
    /// Discography layout: false = 2-row horizontal scroll (default), true = vertical grid.
    @AppStorage("cassette.artistAlbumsGrid") private var artistAlbumsGrid = false
    @Query private var artistFavoriteMatches: [FavoriteRecord]
    @State private var showPinLimitAlert = false

    private var isArtistFavorite: Bool { !artistFavoriteMatches.isEmpty }
    private var isArtistPinned: Bool {
        container?.pinService.isPinned(itemType: .artist, itemId: artistId) == true
    }
    private var effectiveCoverArtId: String? { vm?.artist?.coverArt ?? coverArtId }

    var body: some View {
        Group {
            if let vm {
                artistContent(vm)
            } else {
                LoadingStateView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { artistToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task {
            guard let c = container else { return }
            if vm == nil {
                vm = ArtistDetailViewModel(
                    artistId: artistId,
                    libraryService: c.libraryService,
                    recommendationService: c.recommendationService,
                    imageResolver: c.externalArtistImageResolver
                )
            }
            await vm?.load()
            await vm?.loadTopSongs()
            await vm?.loadSimilarArtists()
        }
        .sheet(item: $selectedOutOfLibraryArtist) { rec in
            OutOfLibraryArtistSheet(
                artist: rec,
                imageURL: vm?.outOfLibraryArtistImages[rec.id] ?? nil,
                providers: container?.externalProvidersStore.load() ?? []
            )
        }
        .alert(String(localized: "Pin Limit Reached", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isPresented: $showPinLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
    }

    private func artistContent(_ vm: ArtistDetailViewModel) -> some View {
        let albums = vm.artist?.album ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                heroSection(vm: vm)

                // Biography — skeleton while first load is in progress, then fade in (or collapse if none).
                if vm.isLoading && vm.artistBiography == nil {
                    ArtistBioSkeleton()
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                } else if let bio = vm.artistBiography {
                    ArtistBioView(bio: bio, lastFmURL: nil)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                if let featured = latestRelease(vm) {
                    featuredReleaseSection(featured)
                }

                if vm.isLoadingTopSongs {
                    topSongsSkeleton
                } else if !vm.topSongs.isEmpty {
                    topSongsSection(vm: vm)
                }

                if !albums.isEmpty {
                    albumsGridSection(albums)
                }

                let similar = vm.similarArtists
                if vm.isLoadingSimilarArtists || !similar.isEmpty {
                    similarArtistsSection(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, CassetteMacOSLayout.playerBarReservedHeight / 2)
            // Cross-fade the skeleton into the bio smoothly when it resolves.
            .animation(.easeInOut(duration: 0.35), value: vm.artistBiography)
        }
        .refreshable { await vm.reloadAll() }
    }

    // MARK: - Top songs / latest release

    private func latestRelease(_ vm: ArtistDetailViewModel) -> AlbumID3? {
        ArtistAlbumCategorizer.sortedByNewest(vm.artist?.album ?? []).first
    }

    private func featuredReleaseSection(_ album: AlbumID3) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text("Latest Release")
                .font(.cassetteSectionTitle)
                .padding(.horizontal, 32)
            NavigationLink(value: HomeDestination.album(album)) {
                HStack(spacing: CassetteSpacing.m) {
                    CoverArtView(id: album.coverArt ?? album.id, size: 200, tier: .hero)
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.name)
                            .foregroundStyle(.primary)
                            .font(.cassetteCellTitle)
                            .lineLimit(2)
                        if let year = ReleaseDateFormatting.yearOnly(from: album.releaseDate ?? album.originalReleaseDate) ?? album.year {
                            Text(verbatim: "\(year)")
                                .font(.cassetteCaption)
                                .foregroundStyle(.secondary)
                        }
                        Text(CassetteCountLabel.songs(album.songCount))
                            .font(.cassetteCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 32)
            }
            .buttonStyle(.plain)
            .albumLongPressMenu(album)
        }
    }

    private func topSongsSection(vm: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text("Top Songs")
                .font(.cassetteSectionTitle)
                .padding(.horizontal, 32)
            VStack(spacing: 0) {
                ForEach(Array(vm.topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task { try? await container?.playerService.play(tracks: vm.topSongs, startIndex: index) }
                    } label: {
                        SongRow(
                            song: song,
                            index: index + 1,
                            showCoverArt: true,
                            showArtist: false
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 32)
                }
            }
        }
    }

    private var topSongsSkeleton: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text("Top Songs")
                .font(.cassetteSectionTitle)
                .padding(.horizontal, 32)
            VStack(spacing: CassetteSpacing.m) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: CassetteSpacing.m) {
                        SkeletonBlock(width: 44, height: 44, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 180, height: 13, cornerRadius: 4)
                            SkeletonBlock(width: 120, height: 11, cornerRadius: 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Albums grid

    /// Two fixed rows — the album grid scrolls horizontally (2×N).
    private var albumGridRows: [GridItem] {
        [GridItem(.fixed(230), spacing: 24),
         GridItem(.fixed(230), spacing: 24)]
    }

    private var albumGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)]
    }

    @ViewBuilder
    private func albumsGridSection(_ albums: [AlbumID3]) -> some View {
        // Show originals only — reissues / remasters / special editions surface in the
        // album detail "Other Versions" tab instead of this discography.
        let displayed = ArtistAlbumCategorizer.originalsOnly(albums)
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            HStack {
                Text("Albums")
                    .font(.cassetteSectionTitle)
                Spacer()
                AlbumSortMenu(sort: $albumSort)
                Button {
                    artistAlbumsGrid.toggle()
                } label: {
                    Image(systemName: artistAlbumsGrid ? "rectangle.grid.1x2" : "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(artistAlbumsGrid ? "Horizontal view" : "Grid view")
            }
            .padding(.horizontal, 32)

            if artistAlbumsGrid {
                LazyVGrid(columns: albumGridColumns, spacing: 24) {
                    ForEach(albumSort.sorted(displayed)) { album in
                        NavigationLink(value: HomeDestination.album(album)) {
                            AlbumGridCell(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: albumGridRows, alignment: .top, spacing: 24) {
                        ForEach(albumSort.sorted(displayed)) { album in
                            NavigationLink(value: HomeDestination.album(album)) {
                                AlbumGridCell(album: album)
                                    .frame(width: 180)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Similar Artists

    @ViewBuilder
    private func similarArtistsSection(vm: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text("Similar Artists")
                .font(.cassetteSectionTitle)
                .padding(.horizontal, 32)

            if vm.isLoadingSimilarArtists {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CassetteSpacing.m) {
                        ForEach(0..<8, id: \.self) { _ in
                            VStack(spacing: CassetteSpacing.xs) {
                                SkeletonBlock(width: 64, height: 64, cornerRadius: 32)
                                SkeletonBlock(width: 72, height: 10)
                            }
                            .frame(width: 80)
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .allowsHitTesting(false)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CassetteSpacing.m) {
                        ForEach(vm.similarArtists) { rec in
                            Group {
                                if rec.inLibrary {
                                    NavigationLink(value: HomeDestination.artist(ArtistID3(id: rec.id, name: rec.name))) {
                                        SimilarArtistCell(
                                            recommendation: rec,
                                            externalImageURL: vm.outOfLibraryArtistImages[rec.id] ?? nil,
                                            onOutOfLibraryTap: { selectedOutOfLibraryArtist = rec }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    SimilarArtistCell(
                                        recommendation: rec,
                                        externalImageURL: vm.outOfLibraryArtistImages[rec.id] ?? nil,
                                        onOutOfLibraryTap: { selectedOutOfLibraryArtist = rec }
                                    )
                                }
                            }
                            .frame(width: 80)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: - Hero

    private func heroSection(vm: ArtistDetailViewModel) -> some View {
        HStack(alignment: .center, spacing: 32) {
            coverCircle
            heroMetadata(vm: vm)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CassetteMacOSLayout.heroHeight)
    }

    private var coverCircle: some View {
        CoverArtView(
            id: effectiveCoverArtId ?? artistId,
            size: 480,
            tier: .hero,
            placeholderSystemImage: "person.fill"
        )
        .frame(width: 240, height: 240)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func heroMetadata(vm: ArtistDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.artist?.name ?? artistName)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)

                let count = vm.artist?.albumCount ?? vm.artist?.album?.count
                if let count {
                    Text("\(count) albums")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await playAll(shuffle: false) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.cassetteAccent)
                .disabled(vm.isPlayLoading || vm.artist?.album?.isEmpty ?? true)

                Button {
                    Task { await playAll(shuffle: true) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(vm.isPlayLoading || vm.artist?.album?.isEmpty ?? true)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 240)
    }

    // MARK: - Play all

    private func playAll(shuffle: Bool) async {
        guard let c = container else { return }
        vm?.isPlayLoading = true
        defer { vm?.isPlayLoading = false }
        do {
            let tracks = try await c.libraryService.fetchAllTracks(forArtistID: artistId)
            let queue = shuffle ? tracks.shuffled() : tracks
            try await c.playerService.play(tracks: queue, startIndex: 0)
        } catch CassetteError.artistTracksUnavailable {
            c.toastService.showError("Unable to load artist tracks. Please check your connection and try again.")
        } catch {
            c.toastService.showError("Playback failed. Please try again.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var artistToolbar: some ToolbarContent {
        if showBackButton {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .cassetteGlassButton(size: 28)
                }
                .buttonStyle(.borderless)
                .help("Back")
            }
            .cassetteSharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    if isArtistFavorite {
                        try? await container?.favoritesService.unstar(itemType: .artist, itemId: artistId)
                    } else {
                        try? await container?.favoritesService.star(itemType: .artist, itemId: artistId)
                    }
                }
            } label: {
                Image(systemName: isArtistFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isArtistFavorite ? Color.cassetteAccent : .primary)
                    .cassetteGlassButton(size: 28)
            }
            .buttonStyle(.borderless)
            .disabled(container?.serverState.isOnline != true)
            .help(isArtistFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .cassetteSharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Menu {
                if isArtistPinned {
                    Button {
                        container?.pinService.unpin(itemType: .artist, itemId: artistId)
                    } label: {
                        Label(String(localized: "Unpin from Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        pinCurrentArtist()
                    } label: {
                        Label(String(localized: "Pin to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .cassetteGlassButton(size: 28)
            }
            .menuOrder(.fixed)
            .buttonStyle(.borderless)
            .help(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
        .cassetteSharedBackgroundVisibility(.hidden)
    }

    private func pinCurrentArtist() {
        guard let serverId = container?.serverState.activeServer?.id,
              let pin = container?.pinService else { return }
        do {
            try pin.pin(
                itemType: .artist,
                itemId: artistId,
                displayName: vm?.artist?.name ?? artistName,
                displaySubtitle: "",
                coverArtId: effectiveCoverArtId,
                serverId: serverId
            )
            container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } catch PinError.limitReached {
            showPinLimitAlert = true
        } catch {}
    }
}
#endif
