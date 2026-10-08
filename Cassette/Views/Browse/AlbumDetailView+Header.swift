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

    func albumHeader(vm: AlbumDetailViewModel?, songs: [DisplayableSong]) -> some View {
        ImmersiveCoverHero(
            coverArtId: vm?.coverArtId ?? coverArtId ?? albumId,
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
            floatingHorizontalPadding: 68,
            floatingTopPadding: 24,
            contentTopPadding: 24,
            contentBottomPadding: 24
        ) {
            VStack(spacing: CassetteSpacing.l) {
                albumTitleBlock(vm: vm, songs: songs, alignment: .center)
                    .padding(.horizontal, CassetteSpacing.l)

                albumActionBar(vm: vm, songs: songs, playMaxWidth: 165)
                    .padding(.horizontal, CassetteSpacing.l)

                if let description = vm?.albumDescription, !description.isEmpty {
                    albumAboutPreview(description)
                }

                albumDownloadProgress(vm: vm)
            }
        }
    }

    @ViewBuilder
    func albumTitleBlock(
        vm: AlbumDetailViewModel?,
        songs: [DisplayableSong],
        alignment: HorizontalAlignment
    ) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        VStack(alignment: alignment, spacing: 0) {
            Text(vm?.albumName ?? initialName)
                // Music uses SF Pro Display here rather than the rounded display face.
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(heroTitleInk)
                .multilineTextAlignment(textAlign)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
                .lineSpacing(1)
                .padding(.bottom, CassetteSpacing.xs)
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
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(heroTitleInk)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, CassetteSpacing.s)
                } else {
                    Text(artist)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(heroTitleInk)
                        .padding(.bottom, CassetteSpacing.s)
                }
            }
            if vm == nil {
                SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
            } else if let vm {
                let qualities = AudioQualityClassifier.albumQualities(in: songs)
                HStack(spacing: 6) {
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
                            foreground: headerSecondaryColor,
                            interactive: false,
                            style: .album
                        )
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(headerSecondaryColor)
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
                    .cassetteGlassButton(
                        size: 52,
                        tint: atmosphere.controlGlassTint
                    )
            }
            .disabled(songs.isEmpty)
            .opacity(vm == nil ? 0.4 : 1)

            PlayButton(action: {
                Task {
                    guard !songs.isEmpty else { return }
                    try? await container?.playerService.play(tracks: songs, startIndex: 0)
                }
            }, label: String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isDisabled: songs.isEmpty || (mode == .full && vm?.isDownloadingAlbum == true), accentColor: heroButtonVariant.background, height: usesDesktopDetail ? nil : 52, labelColor: heroButtonVariant.foreground)
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
                        .cassetteGlassButton(
                            size: 52,
                            tint: atmosphere.controlGlassTint
                        )
                }
            } else if vm?.isOffline != true {
                if let vm {
                    if vm.isDownloadingAlbum {
                        Button { Task { await vm.cancelAlbumDownload() } } label: {
                            Image(systemName: "xmark")
                                .font(.cassetteCellTitle)
                                .foregroundStyle(headerTextColor)
                                .cassetteGlassButton(
                                    size: 52,
                                    tint: atmosphere.controlGlassTint
                                )
                        }
                    } else {
                        switch downloadState(for: vm) {
                        case .notDownloaded:
                            Button { Task { await vm.downloadAlbum() } } label: {
                                Image(systemName: "plus")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .cassetteGlassButton(
                                        size: 52,
                                        tint: atmosphere.controlGlassTint
                                    )
                            }
                            .disabled(vm.songs.isEmpty)
                        case .partiallyDownloaded:
                            Button { Task { await vm.downloadMissingTracks() } } label: {
                                Image(systemName: "arrow.down.circle.dotted")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .cassetteGlassButton(
                                        size: 52,
                                        tint: atmosphere.controlGlassTint
                                    )
                            }
                        case .fullyDownloaded:
                            Button {
                                HapticFeedback.heavy.trigger()
                                showDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .cassetteGlassButton(
                                        size: 52,
                                        tint: atmosphere.controlGlassTint
                                    )
                            }
                        }
                    }
                } else {
                    Button { } label: {
                        Image(systemName: "plus")
                            .font(.cassetteCellTitle)
                            .foregroundStyle(headerTextColor)
                            .cassetteGlassButton(
                                size: 52,
                                tint: atmosphere.controlGlassTint
                            )
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
