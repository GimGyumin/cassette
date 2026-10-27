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

extension AlbumDetailContentView {
    // MARK: - Skeleton rows

    @ViewBuilder
    private var skeletonRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: CassetteSpacing.m) {
                SkeletonBlock(width: 20, height: 20, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 200, height: 16, cornerRadius: 4)
                    SkeletonBlock(width: 140, height: 12, cornerRadius: 4)
                }
                Spacer()
            }
            .padding(.vertical, CassetteSpacing.xs)
            .padding(.horizontal, CassetteSpacing.l)
        }
    }

    // MARK: - Compact (phone) body

    var compactAlbumBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let songs = displaySongs()
                albumHeader(vm: viewModel, songs: songs)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: AlbumScrollOffsetKey.self,
                                value: geo.frame(in: .named(AlbumScrollCoordinateSpace.name)).minY
                            )
                        }
                    }
                albumTrackContent(songs: songs)
            }
        }
        .scrollContentBackground(.hidden)
        .cassetteSoftBottomScrollEdge()
        .coordinateSpace(name: AlbumScrollCoordinateSpace.name)
        .onPreferenceChange(AlbumScrollOffsetKey.self) { minY in
            guard viewModel?.acceptsPresentationUpdates != false else { return }
            // minY starts ~0 under the nav bleed; rises negative as the cover scrolls away.
            let distance = max(0, -minY)
            // Only publish a chrome boundary crossing, not every scrolling frame.
            let progress: CGFloat = distance > heroHeight * 0.55 ? 1 : 0
            if navChromeProgress != progress {
                navChromeProgress = progress
            }
        }
        .modifier(AlbumTopBleedModifier(bleed: usesFullBleedArtwork))
        .scrollIndicators(.hidden)
    }

    // MARK: - Desktop (macOS / iPad regular) body

    var desktopAlbumBody: some View {
        let songs = displaySongs()
        return HStack(alignment: .top, spacing: CassetteSpacing.xxl) {
            desktopAlbumSidebar(vm: viewModel, songs: songs)
                .frame(width: CassetteWideLayout.detailSidebarWidth, alignment: .top)

            ScrollView {
                LazyVStack(spacing: 0) {
                    albumTrackContent(songs: songs)
                }
                .padding(.trailing, CassetteSpacing.l)
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, CassetteSpacing.xl)
        .padding(.top, CassetteSpacing.l)
    }

    private func desktopAlbumSidebar(vm: AlbumDetailViewModel?, songs: [DisplayableSong]) -> some View {
        let coverId = vm?.coverArtId ?? coverArtId ?? albumId
        let coverSize = CassetteWideLayout.heroCoverArtSize
        return VStack(alignment: .leading, spacing: CassetteSpacing.l) {
            CoverArtView(
                id: coverId,
                size: 600,
                cornerRadius: CassetteCornerRadius.large,
                initialImage: effectiveInitialImage,
                contentMode: .fill
            )
            .frame(width: coverSize, height: coverSize)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            albumTitleBlock(vm: vm, songs: songs, alignment: .leading)
            albumActionBar(vm: vm, songs: songs, playMaxWidth: .infinity)

            if let description = vm?.albumDescription, !description.isEmpty {
                albumAboutPreview(description)
                    .padding(.horizontal, 0)
            }

            albumDownloadProgress(vm: vm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func albumTrackContent(songs: [DisplayableSong]) -> some View {
        if isLoadingSkeleton {
            skeletonRows
        } else if let vm = viewModel {
            let serverId = container?.serverState.activeServer?.id ?? UUID()
            if songs.isEmpty {
                if mode == .downloadedOnly {
                    EmptyStateView(
                        systemImage: "arrow.down.circle.slash",
                        title: String(localized: "No Downloaded Tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        subtitle: String(localized: "No tracks from this album have been downloaded.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    )
                } else if let error = vm.error {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: String(localized: "Unable to Load Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        subtitle: error.displayMessage,
                        action: .init(label: String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { Task { await vm.load() } }
                    )
                } else {
                    EmptyStateView(
                        systemImage: "music.note",
                        title: String(localized: "No Tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        subtitle: String(localized: "This album doesn't have any tracks yet.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    )
                }
            } else {
                #if os(iOS)
                AlbumTrackDivider(color: headerTextColor.opacity(0.22))
                    .padding(.horizontal, CassetteSpacing.xl)
                #endif

                AlbumSongRows(
                    songs: songs,
                    albumId: albumId,
                    serverId: serverId,
                    albumArtist: vm.artistName,
                    downloadingIds: vm.downloadingIds,
                    titleColor: headerTextColor,
                    secondaryColor: headerSecondaryColor,
                    onTap: { index in
                        Task {
                            do {
                                try await container?.playerService.play(tracks: songs, startIndex: index)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    },
                    onDownload: (mode == .downloadedOnly || vm.isOffline || vm.isDownloadingAlbum) ? nil : { songId in
                        Task { await vm.downloadSong(id: songId) }
                    },
                    onRemoveDownload: { songId in
                        Task { try? await container?.downloadService.remove(songId: songId, serverId: serverId) }
                    },
                    onAddToPlaylist: { song in songToAddToPlaylist = song }
                )

                albumMetadataFooter(vm: vm, songs: songs)
            }

            if !songs.isEmpty, mode == .full,
               vm.artistId != nil,
               !vm.otherAlbumVersions.isEmpty
                || !vm.moreAlbumsByArtist.isEmpty
                || vm.isLoadingMoreAlbums {
                if !vm.otherAlbumVersions.isEmpty {
                    otherVersionsSection(vm: vm, ownsBottomInset: vm.moreAlbumsByArtist.isEmpty && !vm.isLoadingMoreAlbums)
                }
                if !vm.moreAlbumsByArtist.isEmpty || vm.isLoadingMoreAlbums {
                    moreByArtistSection(vm: vm)
                }
            }
        }
    }
}
