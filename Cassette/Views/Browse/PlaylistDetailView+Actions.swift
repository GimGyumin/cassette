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
    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        if isEditing {
            // Same themed hero-button surface as view mode (navBarIcon: opaque circle + headerTextColor) so the
            // edit CTAs match the non-edit ones — NOT system glass capsules, which read the wrong colour here.
            ToolbarItem(placement: .cancellationAction) {
                Button { cancelEdit() } label: { navBarIcon("xmark") }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .primaryAction) {
                // Trash: multi-remove the selected tracks; with nothing selected, delete the whole playlist
                // (confirmed via dialog). Both mutate only the local working list until Done persists.
                Button(role: .destructive) {
                    if selectedSongIds.isEmpty { showDeletePlaylistConfirm = true } else { showRemoveSongsConfirm = true }
                } label: {
                    navBarIcon("trash", tint: .red)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAddMusic = true } label: { navBarIcon("plus") }
                    .buttonStyle(.plain)
                    .disabled(isSaving || container?.serverState.isOnline != true)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small).tint(headerTextColor)
                } else {
                    let canSave = !editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { Task { isSaving = true; await commitEdit(); isSaving = false } } label: { navBarIcon("checkmark") }
                        .buttonStyle(.plain)
                        .disabled(!canSave)
                }
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    navBarIcon("chevron.left")
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddMusic = true
                } label: {
                    navBarIcon("plus")
                }
                .buttonStyle(.plain)
                .disabled(container?.serverState.isOnline != true || viewModel?.playlistDetail == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                CassetteShareButtonWithOptions(
                    itemID: playlistId,
                    shareOptions: ShareSettings.shared.makeAlbumOptions(
                        albumName: viewModel?.name.isEmpty == false ? (viewModel?.name ?? initialName) : initialName
                    ),
                    fallbackText: playlistShareText(songCount: resolvedSongs(viewModel).count),
                    style: .circle(foreground: headerTextColor)
                )
                .buttonStyle(.plain)
                .disabled(viewModel == nil)
                .accessibilityLabel(String(localized: "Share", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
            ToolbarItem(placement: .primaryAction) {
                playlistMoreMenu
            }
        }
    }

    @ViewBuilder
    private var playlistMoreMenu: some View {
        let songs = resolvedSongs(viewModel)
        let isOnline = container?.serverState.isOnline == true
        let pinned = container?.pinService.isPinned(itemType: .playlist, itemId: playlistId) == true
        let nowPlayingTitle = container?.playerState.currentTrack?.title
        Menu {
            if let vm = viewModel, vm.isOffline != true {
                ControlGroup {
                    playlistDownloadMenuButtons(vm: vm)
                    CassetteShareButtonWithOptions(
                        itemID: playlistId,
                        shareOptions: ShareSettings.shared.makeAlbumOptions(albumName: viewModel?.name.isEmpty == false ? (viewModel?.name ?? initialName) : initialName),
                        fallbackText: playlistShareText(songCount: songs.count)
                    )
                }
            }

            if pinned {
                Button {
                    HapticFeedback.light.trigger()
                    container?.pinService.unpin(itemType: .playlist, itemId: playlistId)
                } label: {
                    Label(String(localized: "Unpin Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin.slash")
                }
            } else {
                Button {
                    pinCurrentPlaylist()
                } label: {
                    Label(String(localized: "Pin Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin")
                }
            }

            Button {
                showAddMusic = true
            } label: {
                Label(String(localized: "Add Songs…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "text.badge.plus")
            }
            .disabled(!isOnline || viewModel?.playlistDetail == nil)

            Divider()

            Button {
                enterEdit()
            } label: {
                Label(String(localized: "Edit", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pencil")
            }
            .disabled(!isOnline || viewModel?.playlistDetail == nil)

            Menu {
                Button {
                    Task { await setPlaylistVisibility(false) }
                } label: {
                    Label("Private", systemImage: viewModel?.playlistDetail?.isPublic == true ? "lock" : "checkmark")
                }
                Button {
                    Task { await setPlaylistVisibility(true) }
                } label: {
                    Label("Public", systemImage: viewModel?.playlistDetail?.isPublic == true ? "checkmark" : "globe")
                }
            } label: {
                Label("Visibility", systemImage: viewModel?.playlistDetail?.isPublic == true ? "globe" : "lock.fill")
            }
            .disabled(!isOnline || viewModel?.playlistDetail == nil)

            Menu {
                Button(String(localized: "Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Task { await sortPlaylistTracks(by: .title) }
                }
                Button(String(localized: "Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Task { await sortPlaylistTracks(by: .artist) }
                }
                Button(String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Task { await sortPlaylistTracks(by: .album) }
                }
            } label: {
                Label(String(localized: "Sort By", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.up.arrow.down")
            }
            .disabled(!isOnline || songs.count < 2)

            Divider()

            Button {
                playInstantMix(container: container, itemID: playlistId, source: .playlist)
            } label: {
                Label(String(localized: "Instant Mix", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "wand.and.stars")
            }
            .disabled(!isOnline)

            Button {
                Task { await container?.playerService.playNext(songs) }
            } label: {
                Label(String(localized: "Play Next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(songs.isEmpty)

            Button {
                Task { await container?.playerService.addToQueue(songs) }
            } label: {
                if let nowPlayingTitle, !nowPlayingTitle.isEmpty {
                    Label(
                        String(format: String(localized: "Play Later: %@", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), nowPlayingTitle),
                        systemImage: "text.line.last.and.arrowtriangle.forward"
                    )
                } else {
                    Label(String(localized: "Add to Queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
            .disabled(songs.isEmpty)

            Divider()

            Button(role: .destructive) {
                showDeletePlaylistConfirm = true
            } label: {
                Label(String(localized: "Delete Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "trash")
            }
            .disabled(!isOnline)
        } label: {
            navBarIcon("ellipsis")
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .disabled(viewModel == nil)
        .accessibilityLabel(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    @ViewBuilder
    private func playlistDownloadMenuButtons(vm: PlaylistDetailViewModel) -> some View {
        if vm.isDownloadingPlaylist {
            Button {
                Task { await vm.cancelPlaylistDownload() }
            } label: {
                Label(String(localized: "Cancel Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "xmark.circle")
            }
        } else {
            switch downloadState(for: vm) {
            case .notDownloaded:
                Button {
                    Task { await vm.downloadPlaylist() }
                } label: {
                    Label(String(localized: "Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle")
                }
                .disabled(vm.songs.isEmpty)
            case .partiallyDownloaded:
                Button {
                    Task { await vm.downloadMissingTracks() }
                } label: {
                    Label(String(localized: "Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle.dotted")
                }
            case .fullyDownloaded:
                Button(role: .destructive) {
                    HapticFeedback.heavy.trigger()
                    showDeleteAlert = true
                } label: {
                    Label(String(localized: "Remove Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle.fill")
                }
            }
        }
    }

    private func playlistShareText(songCount: Int) -> String {
        let name = viewModel?.name.isEmpty == false ? (viewModel?.name ?? initialName) : initialName
        return "\(name) · \(CassetteCountLabel.songs(songCount))"
    }

    private func pinCurrentPlaylist() {
        guard let serverId = container?.serverState.activeServer?.id,
              let pin = container?.pinService else { return }
        do {
            try pin.pin(
                itemType: .playlist,
                itemId: playlistId,
                displayName: viewModel?.name.isEmpty == false ? (viewModel?.name ?? initialName) : initialName,
                displaySubtitle: CassetteCountLabel.songs(resolvedSongs(viewModel).count),
                coverArtId: effectiveCoverArtId,
                serverId: serverId
            )
            HapticFeedback.success.trigger()
            container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } catch PinError.limitReached {
            HapticFeedback.warning.trigger()
            showPinLimitAlert = true
        } catch {
            Logger.pin.error("PlaylistDetailView: pin failed — \(error)")
        }
    }

    private enum PlaylistTrackSort {
        case title, artist, album
    }

    private func sortPlaylistTracks(by sort: PlaylistTrackSort) async {
        guard let c = container, var songs = viewModel?.songs, songs.count > 1 else { return }
        switch sort {
        case .title:
            songs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            songs.sort {
                ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending
            }
        case .album:
            songs.sort {
                ($0.albumName ?? "").localizedCaseInsensitiveCompare($1.albumName ?? "") == .orderedAscending
            }
        }
        do {
            try await c.playlistService.reorderTracks(playlistId: playlistId, orderedSongIds: songs.map(\.id))
            await viewModel?.load()
            c.toastService.showConfirmation(String(localized: "Playlist sorted", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } catch {
            c.toastService.showError(error.localizedDescription)
        }
    }

    /// A nav-bar icon on the unified hero button surface (opaque solid circle, same variant as the transport
    /// + Play). The opaque circle + `.buttonStyle(.plain)` on the ToolbarItem button replace the native
    /// toolbar Liquid-Glass, so there is a SINGLE background, not two stacked layers.
    private func navBarIcon(_ systemName: String, tint: Color? = nil) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint ?? headerTextColor)
            .cassetteHeroButton(size: 34)
    }
}
