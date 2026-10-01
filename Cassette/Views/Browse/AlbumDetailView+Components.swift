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


struct AlbumTopBleedModifier: ViewModifier {
    let bleed: Bool
    func body(content: Content) -> some View {
        if bleed {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

/// Shared mini-player scroll margin; disabled when “More by” already reserves that space.
struct AlbumMiniPlayerMargin: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.miniPlayerBottomMargin()
        } else {
            content
        }
    }
}

// MARK: - Download state

nonisolated enum AlbumDownloadState {
    case notDownloaded
    case partiallyDownloaded
    case fullyDownloaded
}

// MARK: - Live download indicator rows

/// Sub-view that observes DownloadedTrack changes live via @Query,
/// overriding the isDownloaded flag per row without requiring a VM reload.
struct AlbumSongRows: View {
    let songs: [DisplayableSong]
    let downloadingIds: Set<String>
    let titleColor: Color
    let secondaryColor: Color
    let onTap: (Int) -> Void
    let onDownload: ((String) -> Void)?
    let onRemoveDownload: ((String) -> Void)?
    let onAddToPlaylist: ((DisplayableSong) -> Void)?

    @Query private var downloadedTracks: [DownloadedTrack]
    @Query private var allFavorites: [FavoriteRecord]

    private var favoriteSongIds: Set<String> {
        Set(allFavorites.map(\.id))
    }

    let albumArtist: String?

    init(songs: [DisplayableSong], albumId: String, serverId: UUID, albumArtist: String? = nil, downloadingIds: Set<String> = [], titleColor: Color = .primary, secondaryColor: Color = .secondary, onTap: @escaping (Int) -> Void, onDownload: ((String) -> Void)? = nil, onRemoveDownload: ((String) -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil) {
        self.albumArtist = albumArtist
        self.songs = songs
        self.downloadingIds = downloadingIds
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.onTap = onTap
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onAddToPlaylist = onAddToPlaylist
        let aid = albumId
        let sid = serverId
        _downloadedTracks = Query(
            filter: #Predicate<DownloadedTrack> { track in
                track.albumId == aid && track.serverId == sid
            }
        )
    }

    private var downloadedSongIds: Set<String> {
        Set(downloadedTracks.map(\.songId))
    }

    private var showsDiscHeaders: Bool {
        let discs = Set(songs.compactMap(\.discNumber))
        if discs.count > 1 { return true }
        // Single disc > 1 still deserves a label when tagged.
        if let only = discs.first, only > 1 { return true }
        return false
    }

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            let liveDownloaded = downloadedSongIds.contains(song.id)
            let liveSong = song.withDownloaded(liveDownloaded)
            let isDownloading = downloadingIds.contains(song.id)
            let downloadAction: (() -> Void)? = (liveDownloaded || isDownloading) ? nil : onDownload.map { action in { action(song.id) } }
            let removeAction: (() -> Void)? = liveDownloaded ? onRemoveDownload.map { action in { action(song.id) } } : nil
            let disc = song.discNumber ?? 1
            let showDiscHeader = showsDiscHeaders && (index == 0 || (songs[index - 1].discNumber ?? 1) != disc)

            #if os(macOS)
            if showDiscHeader {
                Text(String(localized: "Disc \(disc)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.cassetteSectionTitle)
                    .foregroundStyle(titleColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CassetteSpacing.l)
                    .padding(.top, index == 0 ? CassetteSpacing.s : CassetteSpacing.l)
                    .padding(.bottom, CassetteSpacing.xs)
            }
            Group {
                SongRow(song: liveSong, index: song.trackNumber ?? (index + 1), showArtist: liveSong.showsArtist(inAlbumBy: albumArtist), isFavorite: favoriteSongIds.contains("song:\(song.id)"), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onAddToPlaylist: onAddToPlaylist)
                    .reservingArtistSpace()
                    .padding(.horizontal, CassetteSpacing.l)
                    .contentShape(Rectangle())
            }
            .onTapGesture { onTap(index) }
            .accessibilityAction { onTap(index) }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                AlbumTrackDivider(color: titleColor.opacity(0.5))
                    .padding(.leading, CassetteSpacing.l + 28 + CassetteSpacing.s)
                    .padding(.trailing, CassetteSpacing.l)
                    .allowsHitTesting(false)
            }
            #else
            VStack(spacing: 0) {
                if showDiscHeader {
                    Text(String(localized: "Disc \(disc)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.cassetteSectionTitle)
                        .foregroundStyle(titleColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CassetteSpacing.l)
                        .padding(.top, index == 0 ? CassetteSpacing.s : CassetteSpacing.l)
                        .padding(.bottom, CassetteSpacing.xs)
                }
                Group {
                    SongRow(song: liveSong, index: song.trackNumber ?? (index + 1), showArtist: liveSong.showsArtist(inAlbumBy: albumArtist), isFavorite: favoriteSongIds.contains("song:\(song.id)"), titleColor: titleColor, secondaryColor: secondaryColor, onDownload: downloadAction, onRemoveDownload: removeAction, isDownloading: isDownloading, onAddToPlaylist: onAddToPlaylist)
                        .reservingArtistSpace()
                        .padding(.horizontal, CassetteSpacing.l)
                        .contentShape(Rectangle())
                }
                .onTapGesture { onTap(index) }
                .accessibilityAction { onTap(index) }
                AlbumTrackDivider(color: titleColor.opacity(0.22))
                    .padding(.leading, CassetteSpacing.l + 28 + CassetteSpacing.s)
                    .padding(.trailing, CassetteSpacing.l)
            }
            #endif
        }
    }
}

/// Keep separators visible on artwork backgrounds and independent of subtitle styling.
struct AlbumTrackDivider: View {
    var color: Color = CassetteColors.border

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(maxWidth: .infinity)
            #if os(iOS)
            .frame(height: 0.5)
            #else
            .frame(height: 1)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

// MARK: - Scroll chrome

struct AlbumScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
