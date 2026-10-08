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
    // MARK: - More menu (Apple Music–style)

    var albumDisplayName: String {
        let name = viewModel?.albumName ?? initialName
        return name.isEmpty ? initialName : name
    }

    var albumShareText: String {
        let artist = viewModel?.artistName ?? ""
        let songs = displaySongs()
        if artist.isEmpty {
            return "\(albumDisplayName) · \(CassetteCountLabel.songs(songs.count))"
        }
        return "\(albumDisplayName) · \(artist) · \(CassetteCountLabel.songs(songs.count))"
    }

    private var isAlbumPinned: Bool {
        container?.pinService.isPinned(itemType: .album, itemId: albumId) == true
    }

    @ViewBuilder
    var albumMoreMenu: some View {
        let songs = displaySongs()
        let nowPlayingTitle = container?.playerState.currentTrack?.title
        Menu {
            ControlGroup {
                Button {
                    if let first = songs.first {
                        songToAddToPlaylist = first
                    }
                } label: {
                    Label(String(localized: "Add to Playlist…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "plus")
                }
                .disabled(songs.isEmpty || !isOnline)

                Button {
                    HapticFeedback.light.trigger()
                    Task {
                        guard let container else { return }
                        do {
                            if isAlbumFavorite {
                                try await container.favoritesService.unstar(itemType: .album, itemId: albumId)
                            } else {
                                try await container.favoritesService.star(itemType: .album, itemId: albumId)
                            }
                        } catch {
                            container.toastService.showError(error.localizedDescription)
                        }
                    }
                } label: {
                    Label(
                        isAlbumFavorite ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        systemImage: isAlbumFavorite ? "star.fill" : "star"
                    )
                }
                .disabled(container?.serverState.activeServer == nil)
            }

            if isAlbumPinned {
                Button {
                    HapticFeedback.light.trigger()
                    container?.pinService.unpin(itemType: .album, itemId: albumId)
                } label: {
                    Label(String(localized: "Unpin from Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin.slash")
                }
            } else {
                Button {
                    pinCurrentAlbum()
                } label: {
                    Label(String(localized: "Pin to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "pin")
                }
            }

            Divider()

            Button {
                playInstantMix(container: container, itemID: albumId, source: .album)
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

            if mode == .full, viewModel?.isOffline != true, let vm = viewModel {
                Divider()
                albumDownloadMenuButtons(vm: vm)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(headerTextColor)
                .cassetteHeroButton(size: 34)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    @ViewBuilder
    private func albumDownloadMenuButtons(vm: AlbumDetailViewModel) -> some View {
        if vm.isDownloadingAlbum {
            Button {
                Task { await vm.cancelAlbumDownload() }
            } label: {
                Label(String(localized: "Cancel Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "xmark.circle")
            }
        } else {
            switch downloadState(for: vm) {
            case .notDownloaded:
                Button {
                    Task { await vm.downloadAlbum() }
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
                    Label(String(localized: "Remove Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "trash")
                }
            }
        }
    }

    private func pinCurrentAlbum() {
        guard let serverId = container?.serverState.activeServer?.id,
              let pin = container?.pinService else { return }
        do {
            try pin.pin(
                itemType: .album,
                itemId: albumId,
                displayName: albumDisplayName,
                displaySubtitle: viewModel?.artistName ?? "",
                coverArtId: albumCoverId,
                serverId: serverId
            )
            HapticFeedback.success.trigger()
            container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        } catch PinError.limitReached {
            HapticFeedback.warning.trigger()
            showPinLimitAlert = true
        } catch {}
    }

    // MARK: - Download state

    func downloadState(for vm: AlbumDetailViewModel) -> AlbumDownloadState {
        let total = vm.songs.count
        guard total > 0 else { return .notDownloaded }
        let downloaded = vm.songs.filter { $0.isDownloaded }.count
        if downloaded == 0 { return .notDownloaded }
        if downloaded == total { return .fullyDownloaded }
        return .partiallyDownloaded
    }
}
