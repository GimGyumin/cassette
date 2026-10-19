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

extension PlaylistDetailView {
    // MARK: - Compact / desktop shells

    /// Kept as List to preserve PlaylistSongRows' .onDelete (swipe-to-remove).
    var compactPlaylistBody: some View {
        List(selection: $selectedSongIds) {
            Group {
                if isEditing {
                    editHeader
                        .transition(.opacity)
                } else {
                    playlistHeader(vm: viewModel)
                        .transition(.opacity)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            playlistListRows
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .ignoresSafeArea(.container, edges: .top)
    }

    var desktopPlaylistBody: some View {
        HStack(alignment: .top, spacing: CassetteSpacing.xxl) {
            if isEditing {
                editHeader
                    .frame(width: CassetteWideLayout.detailSidebarWidth, alignment: .top)
                    .padding(.top, CassetteSpacing.l)
            } else {
                desktopPlaylistSidebar(vm: viewModel)
                    .frame(width: CassetteWideLayout.detailSidebarWidth, alignment: .top)
                    .padding(.top, CassetteSpacing.l)
            }

            List(selection: $selectedSongIds) {
                playlistListRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, CassetteSpacing.xl)
    }

    @ViewBuilder
    private var playlistListRows: some View {
        if isLoadingSkeleton {
            skeletonRows
        } else if isEditing {
            editableSongRows
        } else if let vm = viewModel {
            let songs = resolvedSongs(vm)
            if songs.isEmpty, let error = vm.error {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Unable to Load Playlist",
                    subtitle: vm.isGenerated ? String(localized: "Couldn’t build this mix right now.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : error.displayMessage,
                    action: .init(label: "Retry") { Task { await vm.load() } }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(bodyColor)
            } else if songs.isEmpty {
                EmptyStateView(
                    systemImage: "music.note.list",
                    title: "Empty Playlist",
                    subtitle: "This playlist doesn't have any tracks yet."
                )
                .listRowSeparator(.hidden)
                .listRowBackground(bodyColor)
            } else {
                let serverId = container?.serverState.activeServer?.id ?? UUID()
                let removeTrack: ((Int) -> Void)? = (vm.isOffline || vm.isGenerated) ? nil : { index in
                    Task { await vm.removeTrack(at: index) }
                }
                PlaylistSongRows(
                    songs: songs,
                    serverId: serverId,
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
                    onDownload: (vm.isOffline || vm.isDownloadingPlaylist) ? nil : { songId in
                        Task { await vm.downloadSong(id: songId) }
                    },
                    onRemoveDownload: { songId in
                        Task { try? await container?.downloadService.remove(songId: songId, serverId: serverId) }
                    },
                    onRemove: removeTrack,
                    onContextRemove: removeTrack,
                    onAddToPlaylist: { song in songToAddToPlaylist = song },
                    rowBackground: bodyColor
                )

                let featured = FeaturedArtist.from(songs)
                if !featured.isEmpty {
                    featuredArtistsSection(featured)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(bodyColor)
                }
            }
        }
    }

    private func desktopPlaylistSidebar(vm: PlaylistDetailViewModel?) -> some View {
        let coverSize = CassetteWideLayout.heroCoverArtSize
        return VStack(alignment: .leading, spacing: CassetteSpacing.l) {
            Group {
            if let source = generatedSource {
                PersonalMixArtwork(kind: source.mixKind ?? .essentials)
            } else {
            CoverArtView(
                id: effectiveCoverArtId,
                size: 600,
                cornerRadius: CassetteCornerRadius.large,
                initialImage: initialCoverImage,
                contentMode: .fill
            )
            }
            }
            .frame(width: coverSize, height: coverSize)
            .id(coverRefreshID)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            playlistTitleBlock(vm: vm, alignment: .leading)
            playlistActionBar(vm: vm, playMaxWidth: .infinity)

            if let vm, vm.isDownloadingPlaylist {
                let serverId = container?.serverState.activeServer?.id ?? UUID()
                PlaylistDownloadProgressView(
                    songs: vm.songs,
                    total: vm.songs.count,
                    serverId: serverId,
                    secondaryColor: headerSecondaryColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
