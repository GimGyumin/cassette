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
    // MARK: - Header

    func playlistHeader(vm: PlaylistDetailViewModel?) -> some View {
        ZStack(alignment: .topLeading) {
            // The cover + blurred melt live HERE, in the scroll content (the first row), so they scroll up
            // with the list. ignoresSafeArea(.container, .top) bleeds the cover under the transparent nav bar.
            GeometryReader { geo in
                // Stretchy header: on over-scroll at the top, grow the cover UPWARD to fill the bounce
                // instead of revealing the solid page color behind it.
                let stretch = max(0, geo.frame(in: .global).minY)
                Group {
                if let source = generatedSource {
                    PersonalMixArtwork(kind: source.mixKind ?? .essentials, showsTitle: false)
                        .overlay {
                            LinearGradient(colors: [.clear, bodyColor], startPoint: .top, endPoint: .bottom)
                        }
                } else {
                PlaylistThemedBackground(
                    coverArtId: effectiveCoverArtId,
                    coverImage: initialCoverImage,
                    theme: theme,
                    heroHeight: heroHeight,
                    gradientSpec: gradientSpec,
                    lightMelt: true,
                    meltTargetColor: atmosphere.isThemed ? atmosphere.gradientTop : nil
                )
                }
                }
                .frame(width: geo.size.width, height: heroHeight + stretch)
                .offset(y: -stretch)
                .id(coverRefreshID)
            }
            .frame(height: heroHeight)

            Text(vm?.name.isEmpty == false ? (vm?.name ?? initialName) : initialName)
                .font(.system(size: heroTitleSize, weight: .bold))
                .foregroundStyle(headerTextColor)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, CassetteSpacing.xxxl)
                .padding(.top, 104)

            VStack(spacing: CassetteSpacing.l) {
                playlistTitleBlock(vm: vm, alignment: .center, showsMetadata: false)
                    .padding(.horizontal, CassetteSpacing.xxxl)

                playlistActionBar(vm: vm, playMaxWidth: 180, controlSize: 52)
                    .padding(.horizontal, CassetteSpacing.l)

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
            .frame(maxWidth: .infinity)
            .padding(.bottom, CassetteSpacing.xl)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func playlistTitleBlock(
        vm: PlaylistDetailViewModel?,
        alignment: HorizontalAlignment,
        showsMetadata: Bool = true
    ) -> some View {
        let textAlign: TextAlignment = alignment == .leading ? .leading : .center
        VStack(alignment: alignment, spacing: 0) {
            Text(vm?.name.isEmpty == false ? (vm?.name ?? initialName) : initialName)
                .font(.cassetteDetailTitle)
                .foregroundStyle(headerTextColor)
                .multilineTextAlignment(textAlign)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
                .padding(.bottom, CassetteSpacing.xs)
            if isLoadingSkeleton {
                SkeletonBlock(width: 140, height: 18, cornerRadius: 4)
                    .padding(.bottom, CassetteSpacing.s)
            } else if let owner = vm?.owner {
                Text(owner)
                    .font(.title3)
                    .foregroundStyle(headerSecondaryColor)
                    .padding(.bottom, CassetteSpacing.s)
            }
            if isLoadingSkeleton {
                SkeletonBlock(width: 100, height: 14, cornerRadius: 4)
            } else if vm != nil {
                let count = resolvedSongs(vm).count
                Text(showsMetadata ? metadataLine(count: count, updated: vm?.updatedAt)
                     : vm?.updatedAt.map { String(localized: "Updated \($0.formatted(.relative(presentation: .named)))", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) }
                       ?? CassetteCountLabel.songs(count))
                    .font(.cassetteCaption)
                    .foregroundStyle(headerSecondaryColor.opacity(0.8))
            }
        }
    }

    func playlistActionBar(
        vm: PlaylistDetailViewModel?,
        playMaxWidth: CGFloat?,
        controlSize: CGFloat = 44
    ) -> some View {
        HStack(spacing: CassetteSpacing.m) {
                    Button {
                        HapticFeedback.medium.trigger()
                        Task {
                            let shuffled = resolvedSongs(vm).shuffled()
                            guard !shuffled.isEmpty else { return }
                            try? await container?.playerService.play(tracks: shuffled, startIndex: 0)
                        }
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.cassetteCellTitle)
                            .foregroundStyle(headerTextColor)
                            .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                    }
                    .disabled(resolvedSongs(vm).isEmpty)
                    .opacity(vm == nil ? 0.4 : 1)

                    PlayButton(action: {
                        Task {
                            let songs = resolvedSongs(vm)
                            guard !songs.isEmpty else { return }
                            try? await container?.playerService.play(tracks: songs, startIndex: 0)
                        }
                    }, isDisabled: resolvedSongs(vm).isEmpty || (vm?.isDownloadingPlaylist == true), accentColor: heroButtonVariant.background, labelColor: heroButtonVariant.foreground)
                    .frame(maxWidth: playMaxWidth, minHeight: controlSize)

                    if vm?.isOffline != true {
                        if let vm {
                            if vm.isDownloadingPlaylist {
                                Button { Task { await vm.cancelPlaylistDownload() } } label: {
                                        Image(systemName: "xmark")
                                            .font(.cassetteCellTitle)
                                            .foregroundStyle(headerTextColor)
                                            .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                                }
                            } else {
                                switch downloadState(for: vm) {
                                case .notDownloaded:
                                    Button { Task { await vm.downloadPlaylist() } } label: {
                                        Image(systemName: "arrow.down.circle")
                                            .font(.cassetteCellTitle)
                                            .foregroundStyle(headerTextColor)
                                            .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                                    }
                                    .disabled(vm.songs.isEmpty)
                                case .partiallyDownloaded:
                                    Button { Task { await vm.downloadMissingTracks() } } label: {
                                        Image(systemName: "arrow.down.circle.dotted")
                                            .font(.cassetteCellTitle)
                                            .foregroundStyle(headerTextColor)
                                            .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                                    }
                                case .fullyDownloaded:
                                    Button {
                                        HapticFeedback.heavy.trigger()
                                        showDeleteAlert = true
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.cassetteCellTitle)
                                            .foregroundStyle(headerTextColor)
                                            .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                                    }
                                }
                            }
                        } else {
                            Button { } label: {
                                Image(systemName: "arrow.down.circle")
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .cassetteGlassButton(size: controlSize, tint: atmosphere.controlGlassTint)
                            }
                            .disabled(true)
                            .opacity(0.4)
                        }
                    }
        }
        .buttonStyle(.borderless)
    }

    /// Apple-Music "Featured Artists" rail: the most-present artists in the playlist as tappable circles
    /// → artist detail (reuses the existing `.cassetteNavigateToArtist` notification path). Only artists
    /// with an `artistId` appear (see FeaturedArtist); the circle uses a representative track cover.
    func featuredArtistsSection(_ artists: [FeaturedArtist]) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text("Featured Artists")
                .font(.cassetteSectionTitle)
                .foregroundStyle(headerTextColor)
                .padding(.horizontal, CassetteSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: CassetteSpacing.m) {
                    ForEach(artists) { artist in
                        Button {
                            HapticFeedback.light.trigger()
                            postNavigateToArtist(artistId: artist.id, artistName: artist.name, coverArtId: artist.coverArtId)
                        } label: {
                            VStack(spacing: CassetteSpacing.xs) {
                                FeaturedArtistAvatar(artist: artist, size: 76)
                                Text(artist.name)
                                    .font(.cassetteCaption)
                                    .foregroundStyle(headerSecondaryColor)
                                    .lineLimit(1)
                                    .frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.bottom, CassetteSpacing.s)
            }
        }
        .padding(.top, CassetteSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
