// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

#if canImport(UIKit)
import AVKit
import AVFoundation
#endif

// MARK: - Top-bar favorite

struct FullPlayerFavoriteStarButton: View {
    let playerState: PlayerState
    let container: AppContainer?
    let contentColor: Color

    @Query private var favoriteMatches: [FavoriteRecord]

    init(playerState: PlayerState, container: AppContainer?, contentColor: Color) {
        self.playerState = playerState
        self.container = container
        self.contentColor = contentColor
        let songId = playerState.currentTrack?.id ?? ""
        let cid = "song:\(songId)"
        _favoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
    }

    private var isFavorite: Bool { !favoriteMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    var body: some View {
        Button {
            HapticFeedback.light.trigger()
            let fav = isFavorite
            let songId = playerState.currentTrack?.id ?? ""
            guard !songId.isEmpty else { return }
            Task {
                if fav {
                    try? await container?.favoritesService.unstar(itemType: .song, itemId: songId)
                } else {
                    try? await container?.favoritesService.star(itemType: .song, itemId: songId)
                }
            }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFavorite ? CassetteColors.accent : contentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOnline || playerState.currentTrack == nil)
        .accessibilityLabel(
            isFavorite
                ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        )
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}

// MARK: - Lyrics translate control

struct LyricsTranslateButton: View {
    @Bindable var lyricsViewModel: LyricsViewModel
    let contentColor: Color
    let glassTint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var translationToggleAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.01)
            : .easeInOut(duration: 0.38)
    }

    var body: some View {
        if lyricsViewModel.isTranslating {
            ProgressView()
                .tint(contentColor)
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .padding(CassetteSpacing.s)
        } else {
            Button {
                HapticFeedback.light.trigger()
                if lyricsViewModel.areTranslationsVisible {
                    withAnimation(translationToggleAnimation) {
                        lyricsViewModel.clearTranslation()
                    }
                } else if lyricsViewModel.hasStoredTranslation {
                    withAnimation(translationToggleAnimation) {
                        lyricsViewModel.revealTranslation()
                    }
                } else {
                    Task { await lyricsViewModel.translateCurrentLyrics() }
                }
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        lyricsViewModel.areTranslationsVisible
                            ? CassetteColors.accent
                            : contentColor
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .padding(CassetteSpacing.s)
            .buttonStyle(.plain)
            .accessibilityLabel(
                lyricsViewModel.areTranslationsVisible
                    ? "Hide translation"
                    : "Translate lyrics"
            )
        }
    }
}

// MARK: - Track info section

enum TrackInfoLayout {
    case standard
    case lyricsHeader
}

struct TrackInfoSection: View {
    let playerState: PlayerState
    let container: AppContainer?
    let contentColor: Color
    let secondaryContentColor: Color
    let glassTint: Color
    var layout: TrackInfoLayout = .standard
    var showLyrics: Bool = false
    var showsTranslateBelowMenu: Bool = false
    var showsCoverThumbnail: Bool = true
    var showsFavoriteStar: Bool = true
    var lyricsViewModel: LyricsViewModel?

    @Query private var favoriteMatches: [FavoriteRecord]
    @Query private var downloadedMatches: [DownloadedTrack]
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var songToAddToPlaylist: DisplayableSong?
    @State private var showSongInfo = false
    @State private var isDownloading = false

    init(
        playerState: PlayerState,
        container: AppContainer?,
        contentColor: Color,
        secondaryContentColor: Color,
        glassTint: Color,
        layout: TrackInfoLayout = .standard,
        showLyrics: Bool = false,
        showsTranslateBelowMenu: Bool = false,
        showsCoverThumbnail: Bool = true,
        showsFavoriteStar: Bool = true,
        lyricsViewModel: LyricsViewModel? = nil
    ) {
        self.playerState = playerState
        self.container = container
        self.contentColor = contentColor
        self.secondaryContentColor = secondaryContentColor
        self.glassTint = glassTint
        self.layout = layout
        self.showLyrics = showLyrics
        self.showsTranslateBelowMenu = showsTranslateBelowMenu
        self.showsCoverThumbnail = showsCoverThumbnail
        self.showsFavoriteStar = showsFavoriteStar
        self.lyricsViewModel = lyricsViewModel
        let songId = playerState.currentTrack?.id ?? ""
        let cid = "song:\(songId)"
        _favoriteMatches = Query(filter: #Predicate<FavoriteRecord> { $0.id == cid })
        _downloadedMatches = Query(filter: #Predicate<DownloadedTrack> { $0.songId == songId })
    }

    private var isFavorite: Bool { !favoriteMatches.isEmpty }
    private var isDownloaded: Bool { !downloadedMatches.isEmpty }
    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var isLyricsHeader: Bool { layout == .lyricsHeader }
    private static let collapsedCoverSize: CGFloat = 64
    private var actionButtonSize: CGFloat { isLyricsHeader ? 48 : 44 }
    private var titleText: String {
        if playerState.isLiveStream {
            return playerState.currentRadio?.name ?? "Not Playing"
        }
        return playerState.currentTrack?.title ?? "Not Playing"
    }

    private var coverArtId: String? {
        if playerState.isLiveStream {
            return playerState.currentRadio?.id
        }
        return container?.playbackCoverId(for: playerState.currentTrack)
            ?? playerState.currentTrack?.effectiveCoverArtId
    }

    var body: some View {
        HStack(alignment: .center, spacing: CassetteSpacing.m) {
            if isLyricsHeader, showsCoverThumbnail {
                lyricsCoverThumbnail
            }

            VStack(alignment: .leading, spacing: isLyricsHeader ? 2 : CassetteSpacing.xs) {
                MarqueeText(
                    text: titleText,
                    font: isLyricsHeader ? .title3.weight(.semibold) : .title2.weight(.bold),
                    color: contentColor
                )

                if playerState.currentTrack != nil || playerState.isLiveStream {
                    if !playerState.isPlaybackAvailable {
                        Label("Reconnect to resume", systemImage: "wifi.slash")
                            .font(.callout)
                            .foregroundStyle(secondaryContentColor)
                            .lineLimit(1)
                    } else if playerState.isLiveStream {
                        Text("Live Radio")
                            .font(isLyricsHeader ? .body : .subheadline)
                            .foregroundStyle(secondaryContentColor)
                            .lineLimit(1)
                    } else if let artist = playerState.currentTrack?.artist {
                        Menu {
                            Button {
                                goToAlbum()
                            } label: {
                                GoToDestinationMenuLabel(
                                    title: String(localized: "Go to Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    subtitle: playerState.currentTrack?.albumName,
                                    systemImage: "square.stack"
                                )
                            }
                            .disabled(playerState.currentTrack?.albumId == nil || !isOnline)
                            Button {
                                goToArtist()
                            } label: {
                                GoToDestinationMenuLabel(
                                    title: String(localized: "Go to Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    subtitle: artist,
                                    systemImage: "music.mic"
                                )
                            }
                            .disabled(!isOnline)
                        } label: {
                            Text(artist)
                                .font(isLyricsHeader ? .body : .subheadline)
                                .foregroundStyle(secondaryContentColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isOnline)
                        .accessibilityLabel(artist)
                        .accessibilityHint(String(localized: "Go to album or artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }

                    if let classical = playerState.currentTrack?.classicalSubtitle {
                        Text(classical)
                            .font(isLyricsHeader ? .caption : .footnote)
                            .foregroundStyle(secondaryContentColor.opacity(0.9))
                            .lineLimit(2)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            if playerState.currentTrack != nil || playerState.isLiveStream {
                HStack(spacing: CassetteSpacing.m) {
                    if !playerState.isLiveStream, showsFavoriteStar {
                        favoriteStarButton
                    }

                    if showsTranslateBelowMenu,
                       let lyricsVM = lyricsViewModel,
                       Self.shouldShowLyricsTranslate(lyricsVM) {
                        LyricsTranslateButton(
                            lyricsViewModel: lyricsVM,
                            contentColor: contentColor,
                            glassTint: glassTint
                        )
                    }

                    Menu {
                        if !playerState.isLiveStream {
                            ControlGroup {
                                if isDownloading {
                                    Button {} label: {
                                        Label(String(localized: "Downloading…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle")
                                    }
                                    .disabled(true)
                                } else if isDownloaded {
                                    Button(role: .destructive) {
                                        removeDownload()
                                    } label: {
                                        Label(String(localized: "Remove Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle.fill")
                                    }
                                } else {
                                    Button {
                                        downloadCurrentTrack()
                                    } label: {
                                        Label(String(localized: "Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.down.circle")
                                    }
                                    .disabled(!isOnline || playerState.currentTrack == nil)
                                }

                                Button {
                                    toggleFavorite()
                                } label: {
                                    Label(
                                        isFavorite
                                            ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                                            : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                        systemImage: isFavorite ? "star.slash" : "star"
                                    )
                                }
                                .disabled(!isOnline || playerState.currentTrack == nil)

                                if let track = playerState.currentTrack {
                                    CassetteShareButton(
                                        itemID: track.id,
                                        itemDescription: track.title,
                                        fallbackText: trackShareText
                                    )
                                }
                            }

                            Button {
                                songToAddToPlaylist = playerState.currentTrack
                            } label: {
                                Label(String(localized: "Add to Playlist…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "text.badge.plus")
                            }
                            .disabled(!isOnline || playerState.currentTrack == nil)

                            Divider()

                            Button {
                                Task { await triggerSmartShuffle() }
                            } label: {
                                Label(String(localized: "Create Station", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "dot.radiowaves.left.and.right")
                            }

                            Divider()

                            Button {
                                goToAlbum()
                            } label: {
                                GoToDestinationMenuLabel(
                                    title: String(localized: "Go to Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    subtitle: playerState.currentTrack?.albumName,
                                    systemImage: "square.stack"
                                )
                            }
                            .disabled(playerState.currentTrack?.albumId == nil || !isOnline)

                            Button {
                                goToArtist()
                            } label: {
                                GoToDestinationMenuLabel(
                                    title: String(localized: "Go to Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    subtitle: playerState.currentTrack?.artist,
                                    systemImage: "music.mic"
                                )
                            }
                            .disabled(playerState.currentTrack?.artist == nil || !isOnline)

                            Button {
                                showSongInfo = true
                            } label: {
                                Label(String(localized: "View Credits", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "info.circle")
                            }
                            .disabled(playerState.currentTrack == nil)

                            if showLyrics, let lyricsShareText {
                                ShareLink(item: lyricsShareText) {
                                    Label(
                                        String(localized: "Share Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                        systemImage: "quote.bubble"
                                    )
                                }
                            }
                        } else {
                            Button {
                                Task { await triggerSmartShuffle() }
                            } label: {
                                Label(String(localized: "Smart Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(contentColor)
                            .frame(width: actionButtonSize, height: actionButtonSize)
                            .contentShape(Rectangle())
                    }
                    .menuOrder(.fixed)
                    .buttonStyle(.plain)
                    .accessibilityLabel("More options")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
                .environment(artworkImageCache)
        }
        .sheet(isPresented: $showSongInfo) {
            if let track = playerState.currentTrack {
                SongInfoSheet(song: track, lyricsLines: songInfoLyricsLines)
            }
        }
        .task(id: playerState.currentTrack?.id) {
            isDownloading = false
            guard let track = playerState.currentTrack,
                  let serverId = container?.serverState.activeServer?.id,
                  let downloadService = container?.downloadService else { return }
            isDownloading = await downloadService.isDownloading(songId: track.id, serverId: serverId)
        }
    }

    @ViewBuilder
    private var lyricsCoverThumbnail: some View {
        let size = Self.collapsedCoverSize
        Group {
            if let coverArtId {
                CoverArtView(
                    id: coverArtId,
                    size: 160,
                    contentMode: .fill
                )
            } else {
                RoundedRectangle(cornerRadius: CassetteCornerRadius.standard, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(secondaryContentColor)
                    }
            }
        }
        .frame(width: size, height: size)
        .cassetteCoverStyle(cornerRadius: CassetteCornerRadius.standard)
        .accessibilityHidden(true)
    }

    private var songInfoLyricsLines: [String] {
        guard let lyricsViewModel else { return [] }
        switch lyricsViewModel.state {
        case .loaded(let lyrics):
            return lyrics.line.map(\.value).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        default:
            return []
        }
    }

    private static func shouldShowLyricsTranslate(_ lyricsVM: LyricsViewModel) -> Bool {
        guard LyricsTranslationSettings.shared.isTranslationEnabled else { return false }
        guard case .loaded = lyricsVM.state else { return false }
        return lyricsVM.needsTranslation
    }

    private var trackShareText: String {
        let title = playerState.currentTrack?.title ?? ""
        let artist = playerState.currentTrack?.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if artist.isEmpty { return title }
        return "\(title) — \(artist)"
    }

    private var lyricsShareText: String? {
        let lines = songInfoLyricsLines
        guard !lines.isEmpty else { return nil }
        return trackShareText + "\n\n" + lines.joined(separator: "\n")
    }

    private func toggleFavorite() {
        HapticFeedback.light.trigger()
        let fav = isFavorite
        let songId = playerState.currentTrack?.id ?? ""
        guard !songId.isEmpty else { return }
        Task {
            if fav {
                try? await container?.favoritesService.unstar(itemType: .song, itemId: songId)
            } else {
                try? await container?.favoritesService.star(itemType: .song, itemId: songId)
            }
        }
    }

    private var favoriteStarButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFavorite ? CassetteColors.accent : contentColor)
                .frame(width: actionButtonSize, height: actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOnline || playerState.currentTrack == nil)
        .accessibilityLabel(
            isFavorite
                ? String(localized: "Remove from Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Add to Favorites", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        )
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }

    private func downloadCurrentTrack() {
        guard let track = playerState.currentTrack,
              let serverId = container?.serverState.activeServer?.id,
              let downloadService = container?.downloadService else { return }
        isDownloading = true
        HapticFeedback.light.trigger()
        Task {
            defer { isDownloading = false }
            do {
                try await downloadService.download(song: track.asSong(), serverId: serverId)
            } catch {
                container?.toastService.showError(error.localizedDescription)
            }
        }
    }

    private func removeDownload() {
        guard let track = playerState.currentTrack,
              let serverId = container?.serverState.activeServer?.id,
              let downloadService = container?.downloadService else { return }
        HapticFeedback.light.trigger()
        Task {
            try? await downloadService.remove(songId: track.id, serverId: serverId)
        }
    }

    private func goToAlbum() {
        guard let track = playerState.currentTrack, track.albumId != nil else { return }
        #if os(macOS)
        postNavigateToAlbum(track: track)
        #else
        postNavigateToAlbum(track: track)
        #endif
    }

    private func goToArtist() {
        guard let track = playerState.currentTrack else { return }
        if track.artistId != nil {
            postNavigateToArtist(track: track)
            return
        }
        guard let name = track.artist else { return }
        Task {
            guard let c = container,
                  let result = try? await c.libraryService.search(name),
                  let found = result.artist?.first else { return }
            postNavigateToArtist(artistId: found.id, artistName: found.name, coverArtId: found.coverArt)
        }
    }

    private func triggerSmartShuffle() async {
        guard let container else { return }
        do {
            try await container.playerService.playSmartShuffle()
        } catch {
            container.toastService.showError(smartShuffleErrorMessage(from: error))
        }
    }

    private func smartShuffleErrorMessage(from error: Error) -> String {
        if case CassetteError.smartShuffleEmpty = error {
            return "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use."
        }
        return "Smart Shuffle failed. Please try again."
    }
}
