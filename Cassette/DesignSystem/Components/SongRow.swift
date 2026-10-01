// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import OSLog
import AppIntents

/// Standard track cell for album and playlist detail screens.
///
/// - `showCoverArt`: show a 44pt thumbnail (useful in playlist context where tracks
///   may come from different albums). Default `false` for album tracks.
struct SongRow: View {
    let song: DisplayableSong
    let index: Int
    var showCoverArt: Bool = false
    /// Show the artist as the subtitle. Default true; pass false where the artist is implied (e.g. the artist
    /// detail page) so the row isn't redundant.
    var showArtist: Bool = true
    var reservesArtistSpace: Bool = false
    var isFavorite: Bool = false
    var titleColor: Color = .primary
    var secondaryColor: Color = .secondary
    let onDownload: (() -> Void)?
    let onRemoveDownload: (() -> Void)?
    var isDownloading: Bool = false
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onAddToPlaylist: ((DisplayableSong) -> Void)? = nil
    /// Show an ellipsis in place of the track duration (album detail keeps durations in its
    /// footer instead of per-row).
    var showsEllipsisInsteadOfDuration: Bool = false

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.cassettePlayingAccent) private var playingAccent
    @State private var coverImage: PlatformImage?
    @State private var showPinLimitAlert = false
    @State private var pinnedSnapshot = false
    @State private var favoriteSnapshot = false
    #if os(macOS)
    @State private var isHovered = false
    #endif

    init(song: DisplayableSong, index: Int, showCoverArt: Bool = false, showArtist: Bool = true, isFavorite: Bool = false, titleColor: Color = .primary, secondaryColor: Color = .secondary, onDownload: (() -> Void)? = nil, onRemoveDownload: (() -> Void)? = nil, isDownloading: Bool = false, onRemoveFromPlaylist: (() -> Void)? = nil, onAddToPlaylist: ((DisplayableSong) -> Void)? = nil, showsEllipsisInsteadOfDuration: Bool = false) {
        self.song = song
        self.index = index
        self.showCoverArt = showCoverArt
        self.showArtist = showArtist
        self.isFavorite = isFavorite
        self.titleColor = titleColor
        self.secondaryColor = secondaryColor
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.isDownloading = isDownloading
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onAddToPlaylist = onAddToPlaylist
        self.showsEllipsisInsteadOfDuration = showsEllipsisInsteadOfDuration
    }

    func reservingArtistSpace() -> Self {
        var row = self
        row.reservesArtistSpace = true
        row.showsEllipsisInsteadOfDuration = true
        return row
    }

    private var isOnline: Bool { container?.serverState.isOnline == true }
    private var isCurrentTrack: Bool { container?.playerState.currentTrack?.id == song.id }
    private var isPlaying: Bool { container?.playerState.playbackState == .playing }
    private var isPinned: Bool {
        pinnedSnapshot
    }

    var body: some View {
        HStack(alignment: reservesArtistSpace ? .top : .center, spacing: CassetteSpacing.s) {
            if showCoverArt {
                CoverArtCard(id: song.coverArtId ?? song.id, size: 44)
                    .overlay {
                        // Now-playing equalizer over the thumbnail (with a scrim) for the current track —
                        // restores the playing cue lost when rows switched to album thumbnails (showCoverArt).
                        if isCurrentTrack {
                            ZStack {
                                Color.black.opacity(0.45)
                                NowPlayingBarsIndicator(isPlaying: isPlaying)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.standard))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(playingAccent)
                                .padding(3)
                        }
                    }
            } else {
                ZStack {
                    if isCurrentTrack {
                        NowPlayingBarsIndicator(isPlaying: isPlaying)
                    } else {
                        Text("\(song.trackNumber ?? index)")
                            #if os(macOS)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            #else
                            .font(reservesArtistSpace ? .system(size: 18, weight: .regular) : .cassetteCaption)
                            .foregroundStyle(secondaryColor)
                            #endif
                            .monospacedDigit()
                            .opacity(isFavorite && !reservesArtistSpace ? 0 : 1)
                        if isFavorite && !reservesArtistSpace {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(playingAccent)
                                .accessibilityLabel("Favorite")
                        }
                    }
                }
                .frame(width: 28, alignment: .center)
                .overlay(alignment: .leading) {
                    if reservesArtistSpace && isFavorite {
                        Circle()
                            .fill(secondaryColor)
                            .frame(width: 5, height: 5)
                            .offset(x: -8)
                            .accessibilityLabel(String(localized: "Favorite", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    #if os(macOS)
                    .font(.system(size: 14, weight: .regular))
                    #else
                    .font(reservesArtistSpace ? .system(size: 18, weight: .regular) : .cassetteCellTitle)
                    #endif
                    .foregroundStyle(isCurrentTrack ? playingAccent : titleColor)
                    #if os(macOS)
                    .lineLimit(reservesArtistSpace ? nil : 1)
                    #else
                    .lineLimit(reservesArtistSpace ? 2 : 1)
                    .lineSpacing(reservesArtistSpace ? 1 : 0)
                    #endif
                    .fixedSize(horizontal: false, vertical: true)
                if !reservesArtistSpace, let classical = song.classicalSubtitle {
                    Text(classical)
                        #if os(macOS)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        #else
                        .font(.cassetteCaption)
                        .foregroundStyle(secondaryColor)
                        #endif
                        .lineLimit(1)
                } else if showArtist, let artist = song.artist {
                    Text(artist)
                        #if os(macOS)
                        .font(.system(size: reservesArtistSpace ? 13 : 12))
                        .foregroundStyle(.secondary)
                        #else
                        .font(reservesArtistSpace ? .subheadline : .cassetteCaption)
                        .foregroundStyle(secondaryColor)
                        #endif
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: CassetteSpacing.s) {
                if song.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.cassetteCaption)
                        .foregroundStyle(secondaryColor.opacity(0.85))
                } else if isDownloading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                if showsEllipsisInsteadOfDuration {
                    Menu { songMenu } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(secondaryColor)
                            .frame(width: 32, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(String(localized: "More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } else if song.duration > 0 {
                    Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond)))
                        #if os(macOS)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        #else
                        .font(.cassetteCaption)
                        .foregroundStyle(secondaryColor.opacity(0.85))
                        #endif
                        .monospacedDigit()
                }
            }
        }
        #if os(macOS)
        .padding(.vertical, reservesArtistSpace ? 12 : CassetteSpacing.s)
        .padding(.trailing, CassetteSpacing.s)
        #else
        .padding(.vertical, reservesArtistSpace ? 14 : CassetteSpacing.s)
        #endif
        .contentShape(Rectangle())
        #if os(macOS)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        #endif
        .task(id: song.id) {
            pinnedSnapshot = container?.pinService.isPinned(itemType: .song, itemId: song.id) == true
            favoriteSnapshot = isFavorite
            coverImage = await artworkImageCache.load(coverArtId: song.coverArtId ?? song.id)
        }
        .contextMenu { songMenu } preview: {
            SongContextPreview(coverImage: coverImage, song: song)
        }
        .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PinError.limitReached.errorDescription ?? "")
        }
        .appEntityIdentifier(songEntityIdentifier)
    }

    /// Onscreen-awareness identifier for this row. `nil` before iOS 27 or when
    /// no active server is known.
    @MainActor
    private var songEntityIdentifier: EntityIdentifier? {
        if #available(iOS 27.0, macOS 27.0, *) {
            return OnscreenEntityAnnotation.songIdentifier(
                for: song,
                serverId: container?.serverState.activeServer?.id
            )
        }
        return nil
    }

    @ViewBuilder
    private var songMenu: some View {
            ControlGroup {
                Button {
                    toggleFavorite()
                } label: {
                    Label(
                        favoriteSnapshot ? "Unfavorite" : "Favorite",
                        systemImage: favoriteSnapshot ? "star.fill" : "star"
                    )
                }
                .disabled(!isOnline)

                ShareLink(item: songShareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            Button {
                Task {
                    do {
                        try await container?.playerService.play(tracks: [song], startIndex: 0)
                        donatePlayIfAvailable()
                    } catch {
                        Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                Task { await container?.playerService.playNext(song) }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                Task { await container?.playerService.addToQueue(song) }
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }

            Divider()

            if isPinned {
                Button {
                    HapticFeedback.light.trigger()
                    container?.pinService.unpin(itemType: .song, itemId: song.id)
                    pinnedSnapshot = false
                } label: {
                    Label("Unpin from Home", systemImage: "pin.slash")
                }
            } else {
                Button {
                    guard let serverId = container?.serverState.activeServer?.id,
                          let pin = container?.pinService else { return }
                    do {
                        try pin.pin(
                            itemType: .song,
                            itemId: song.id,
                            displayName: song.title,
                            displaySubtitle: song.artist ?? "",
                            coverArtId: song.coverArtId,
                            serverId: serverId
                        )
                        pinnedSnapshot = true
                        HapticFeedback.success.trigger()
                        container?.toastService.showConfirmation(String(localized: "Pinned to Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    } catch PinError.limitReached {
                        HapticFeedback.warning.trigger()
                        showPinLimitAlert = true
                    } catch {}
                } label: {
                    Label("Pin to Home", systemImage: "pin")
                }
            }

            Button {
                onAddToPlaylist?(song)
            } label: {
                Label("Add to Playlist...", systemImage: "music.note.list")
            }
            .disabled(!isOnline)

            if let action = onRemoveFromPlaylist {
                Divider()
                Button(role: .destructive, action: action) {
                    Label("Remove from Playlist", systemImage: "minus.circle")
                }
            }

            if !song.isDownloaded && !isDownloading, let action = onDownload {
                Button(action: action) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }

            if song.isDownloaded, let action = onRemoveDownload {
                Button(role: .destructive, action: action) {
                    Label("Remove Download", systemImage: "trash")
                }
            }

            // TODO(v1.5.x): Add "Show in Album" and "Show in Artist". Requires:
            // (1) albumId + artistId fields on DisplayableSong, (2) NavigationPath
            // lifted into RootViewMacOS and threaded through all section views.
    }

    private var songShareText: String {
        [song.title, song.artist, song.albumName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private func toggleFavorite() {
        let favorite = favoriteSnapshot
        favoriteSnapshot.toggle()
        Task {
            do {
                if favorite {
                    try await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
                } else {
                    try await container?.favoritesService.star(itemType: .song, itemId: song.id)
                }
                donateAffinityIfAvailable(isLiked: !favorite)
            } catch {
                favoriteSnapshot = favorite
            }
        }
    }

    @MainActor
    private func donatePlayIfAvailable() {
        guard #available(iOS 27.0, macOS 27.0, *),
              let serverId = container?.serverState.activeServer?.id else { return }
        SiriDonations.donatePlay(song: song, serverId: serverId)
    }

    @MainActor
    private func donateAffinityIfAvailable(isLiked: Bool) {
        guard #available(iOS 27.0, macOS 27.0, *),
              let serverId = container?.serverState.activeServer?.id else { return }
        SiriDonations.donateAffinity(song: song, serverId: serverId, isLiked: isLiked)
    }
}
