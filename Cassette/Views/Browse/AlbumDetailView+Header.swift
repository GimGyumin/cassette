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
    // MARK: - Header

    @ViewBuilder
    func albumHeader(vm: AlbumDetailViewModel?, songs: [DisplayableSong]) -> some View {
        if artworkStyle == .faded {
            ScrollLinkedFadedArtworkHero(coverArtId: albumCoverId, initialImage: effectiveInitialImage,
                             background: atmosphere.pageColor, title: albumDisplayName,
                             treatment: artworkAnalysis?.fadedTreatment ?? .textured,
                             edgeColor: artworkAnalysis?.bottomBackground,
                             topColor: artworkAnalysis?.topBackground,
                             topInsetPoints: artworkTopInset) {
                albumHeaderInformation(vm: vm, songs: songs, includesTitle: false)
                    .padding(.bottom, CassetteSpacing.xxl)
            }
            .id(albumCoverId)
        } else if artworkStyle == .uniform {
            VStack(spacing: 0) {
                SeamlessArtworkHero(coverArtId: albumCoverId, initialImage: effectiveInitialImage,
                                    background: atmosphere.pageColor)
                albumHeaderInformation(vm: vm, songs: songs)
                    .padding(.top, CassetteSpacing.s)
                    .padding(.bottom, CassetteSpacing.xxl)
            }
        } else {
            ImmersiveCoverHero(
                coverArtId: albumCoverId,
                coverImage: effectiveInitialImage,
                theme: theme,
                heroHeight: heroHeight,
                contentBelow: true,
                fillCover: true,
                meltTargetColor: atmosphere.isThemed ? atmosphere.pageColor : nil,
                showBlurredMelt: false,
                showsFloatingShadow: false,
                coverShadowColor: atmosphere.coverShadowColor,
                floatingInset: true,
                floatingHorizontalPadding: CassetteAlbumLayout.coverSideInset,
                floatingTopPadding: CassetteSpacing.xxl,
                contentTopPadding: CassetteSpacing.xxl,
                contentBottomPadding: CassetteSpacing.xxl
            ) {
                albumHeaderInformation(vm: vm, songs: songs)
            }
        }
    }

    private func albumHeaderInformation(vm: AlbumDetailViewModel?, songs: [DisplayableSong], includesTitle: Bool = true) -> some View {
        VStack(spacing: artworkStyle == .faded ? CassetteSpacing.m : CassetteSpacing.l) {
            albumTitleBlock(vm: vm, songs: songs, alignment: .center, includesTitle: includesTitle)
                .anchorPreference(key: FadedArtworkLayoutKey.self, value: .bounds) { .init(details: $0) }
                .padding(.horizontal, CassetteSpacing.xl)
            albumActionBar(vm: vm, songs: songs,
                           playMaxWidth: artworkStyle == .faded ? CassetteAlbumLayout.fadedPlayWidth : (usesFullBleedArtwork ? .infinity : CassetteAlbumLayout.insetPlayWidth))
                .padding(.horizontal, usesFullBleedArtwork ? CassetteSpacing.xxxl : CassetteSpacing.l)
                .padding(.top, artworkStyle == .faded ? CassetteSpacing.xs : (usesFullBleedArtwork ? CassetteSpacing.s : 0))
            if let description = vm?.albumDescription, !description.isEmpty {
                albumAboutPreview(description)
            }
            albumDownloadProgress(vm: vm)
        }
    }

    @ViewBuilder
    func albumTitleBlock(
        vm: AlbumDetailViewModel?,
        songs: [DisplayableSong],
        alignment: HorizontalAlignment,
        includesTitle: Bool = true
    ) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        VStack(alignment: alignment, spacing: 0) {
            if includesTitle {
                Text(albumDisplayName)
                    // Music uses SF Pro Display here rather than the rounded display face.
                    .font(usesFullBleedArtwork ? .cassetteAlbumTitle : .cassetteAlbumCardTitle)
                    .foregroundStyle(heroTitleInk)
                    .multilineTextAlignment(textAlign)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
                    .lineSpacing(1)
                    .padding(.bottom, CassetteSpacing.xs)
            }
            if vm == nil {
                SkeletonBlock(width: 140, height: 18, cornerRadius: 4)
                    .padding(.bottom, CassetteSpacing.s)
            } else if let artist = vm?.artistName {
                if let artistId = vm?.artistId, vm?.isOffline != true {
                    // A unique push (see `HomeDestination.artistPush`): an id-only `artistById` value that
                    // matches an artist already in the path makes NavigationStack reuse that entry — the
                    // album would be dropped from the stack and the back button would stop responding.
                    DetailNavigationLink(destination: HomeDestination.artistPush(
                        id: artistId,
                        name: artist,
                        coverArtId: nil,
                        token: artistRouteToken
                    )) {
                        Text(artist)
                            .font(.cassetteAlbumArtist)
                            .foregroundStyle(heroTitleInk)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, CassetteSpacing.s)
                } else {
                    Text(artist)
                        .font(.cassetteAlbumArtist)
                        .foregroundStyle(heroTitleInk)
                        .padding(.bottom, CassetteSpacing.s)
                }
            }
            if vm == nil {
                SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
            } else if let vm {
                let qualities = vm.audioQualities
                HStack(spacing: CassetteSpacing.xs) {
                    if let genre = vm.genre, !genre.isEmpty {
                        Text(genre)
                    }
                    if let year = vm.year {
                        if vm.genre?.isEmpty == false { Text("·") }
                        Text(ReleaseDateFormatting.yearLabel(year))
                    }
                    ForEach(qualities.indices, id: \.self) { index in
                        if index > 0 || vm.year != nil || (vm.genre?.isEmpty == false) {
                            Text("·")
                        }
                        AudioQualityLabelView(
                            quality: qualities[index],
                            foreground: artworkStyle == .faded ? albumMetadataInk : headerTextColor,
                            interactive: false,
                            style: .album
                        )
                    }
                }
                .font(.cassetteFootnote)
                .foregroundStyle(albumMetadataInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
    }

    func albumActionBar(
        vm: AlbumDetailViewModel?,
        songs: [DisplayableSong],
        playMaxWidth: CGFloat?
    ) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            Button {
                HapticFeedback.medium.trigger()
                Task {
                    guard !songs.isEmpty else { return }
                    try? await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.cassetteCellTitle)
                    .foregroundStyle(headerTextColor)
                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
            }
            .disabled(songs.isEmpty)
            .opacity(vm == nil ? 0.4 : 1)

            PlayButton(action: {
                Task {
                    guard !songs.isEmpty else { return }
                    try? await container?.playerService.play(tracks: songs, startIndex: 0)
                }
            }, label: String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isDisabled: songs.isEmpty || (mode == .full && vm?.isDownloadingAlbum == true), accentColor: heroButtonVariant.background, height: usesDesktopDetail ? nil : albumControlSide, labelColor: usesFullBleedArtwork ? heroButtonVariant.foreground : (heroButtonVariant.background.luminance > 0.5 ? .black : .white))
            .frame(maxWidth: playMaxWidth)

            if mode == .downloadedOnly {
                Button {
                    HapticFeedback.heavy.trigger()
                    let sid = container?.serverState.activeServer?.id ?? UUID()
                    let tracks = downloadedAlbumTracks
                    Task {
                        for track in tracks {
                            try? await container?.downloadService.remove(songId: track.songId, serverId: sid)
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.cassetteCellTitle)
                        .foregroundStyle(headerTextColor)
                        .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                }
            } else if vm?.isOffline != true {
                if let vm {
                    if vm.isDownloadingAlbum {
                        Button { Task { await vm.cancelAlbumDownload() } } label: {
                            Image(systemName: "xmark")
                                .font(.cassetteCellTitle)
                                .foregroundStyle(headerTextColor)
                                .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                        }
                    } else {
                        switch downloadState(for: vm) {
                        case .notDownloaded:
                            Button { Task { await vm.downloadAlbum() } } label: {
                                Image(systemName: "arrow.down")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                            .disabled(vm.songs.isEmpty)
                        case .partiallyDownloaded:
                            Button { Task { await vm.downloadMissingTracks() } } label: {
                                Image(systemName: "arrow.down")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                        case .fullyDownloaded:
                            Button {
                                HapticFeedback.heavy.trigger()
                                showDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                            }
                        }
                    }
                } else {
                    Button { } label: {
                        Image(systemName: "arrow.down")
                            .font(.cassetteCellTitle)
                            .foregroundStyle(headerTextColor)
                            .albumTransportCircle(ink: headerTextColor, side: albumControlSide)
                    }
                    .disabled(true)
                    .opacity(0.4)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    func albumDownloadProgress(vm: AlbumDetailViewModel?) -> some View {
        if mode == .full, let vm, vm.isDownloadingAlbum {
            let total = vm.songs.count
            let downloaded = downloadedCount
            VStack(spacing: CassetteSpacing.xs) {
                if downloaded == 0 {
                    HStack(spacing: CassetteSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "Starting download…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.cassetteCaption)
                            .foregroundStyle(headerSecondaryColor)
                    }
                } else {
                    ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(atmosphere.isThemed ? atmosphere.contentColor.opacity(0.9) : CassetteColors.accentForeground(on: dominantColor))
                        .frame(maxWidth: 280)
                    Text(String(localized: "Downloading \(downloaded)/\(total) tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.cassetteCaption)
                        .foregroundStyle(headerSecondaryColor)
                }
            }
            .frame(minHeight: 44)
        }
    }
}

private extension View {
    func albumTransportCircle(ink: Color, side: CGFloat) -> some View {
        self
            .font(.cassetteDetailTitle)
            .foregroundStyle(ink)
            .frame(width: side, height: side)
            .background(ink.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(ink.opacity(0.05), lineWidth: 1))
            .contentShape(Circle())
    }
}
