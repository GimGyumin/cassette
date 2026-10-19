// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

struct ContextMenuShareAction: View {
    let itemID: String
    let text: String
    @Environment(\.appContainer) private var container

    var body: some View {
        Button {
            guard let container else { return }
            let options = ShareSettings.shared.makeOptions(trackTitle: text)
            Task {
                do {
                    let client = try await container.serverService.makeSwiftSonicClient()
                    let url = try await client.createShareURL(id: itemID, options: options)
                    #if os(iOS)
                    presentContextMenuShare(url)
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    #endif
                } catch {
                    container.toastService.showError(error.localizedDescription)
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

#if os(iOS)
/// A ShareLink hosted inside UIContextMenu can be dismissed with the menu that created it.
/// Wait for that transient controller to leave, then present from the stable app hierarchy.
private func presentContextMenuShare(_ url: URL) {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }

        var presenter = root
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 1,
            height: 1
        )
        presenter.present(controller, animated: true)
    }
}
#endif

// MARK: - Context menu preview views
// Internal (not private) so SongRow can reference SongContextPreview directly.

struct CollectionContextPreview: View {
    let coverImage: PlatformImage?
    let displayName: String
    let displaySubtitle: String
    /// Artists use a circular avatar; albums/playlists stay square.
    var isArtist: Bool = false

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            artwork
                .frame(width: 112, height: 112)

            HStack(spacing: CassetteSpacing.s) {
                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !displaySubtitle.isEmpty {
                        Text(displaySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CassetteSpacing.m)
        .frame(width: 360)
        .frame(minHeight: 136)
    }

    @ViewBuilder
    private var artwork: some View {
        let content = Group {
            if let coverImage {
                Image(platformImage: coverImage)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: isArtist ? "person.fill" : "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        if isArtist {
            content.clipShape(Circle())
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SongContextPreview: View {
    let coverImage: PlatformImage?
    let song: DisplayableSong

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            Group {
                if let coverImage {
                    Image(platformImage: coverImage)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let artist = song.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let albumName = song.albumName {
                    Text(albumName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CassetteSpacing.m)
        .frame(width: 360)
        .frame(minHeight: 136)
    }
}

// MARK: - Song context menu

/// Adds Play / Play Next / Add to Queue / Pin / Favorite actions for a single song.
struct SongContextMenuModifier: ViewModifier {
    let song: DisplayableSong
    let coverImage: PlatformImage?

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var showPinLimitAlert = false
    @State private var pinnedSnapshot = false
    @State private var favoriteSnapshot = false
    @State private var loadedCoverImage: PlatformImage?
    @State private var showAddToPlaylist = false
    @State private var showAtmosSelection = false

    private var isFavorite: Bool { favoriteSnapshot }
    private var isPinned: Bool { pinnedSnapshot }
    private var isOnline: Bool { container?.serverState.isOnline == true }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: song.id, title: song.title)
            .contextMenu {
                ControlGroup {
                    Button {
                        toggleFavorite()
                    } label: {
                        Label(
                            isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: isFavorite ? "star.fill" : "star"
                        )
                    }
                    .disabled(!isOnline)

                    ContextMenuShareAction(itemID: song.id, text: shareText)
                }

                Divider()

                Button {
                    Task {
                        do {
                            try await container?.playerService.play(tracks: [song], startIndex: 0)
                        } catch {
                            Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                        }
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button {
                    playInstantMix(container: container, itemID: song.id, source: .song)
                } label: {
                    Label("Instant Mix", systemImage: "wand.and.stars")
                }
                .disabled(!isOnline)

                Divider()

                pinButton

                if !AtmosVariantCatalogue.isAtmos(song) {
                    Button { showAtmosSelection = true } label: {
                        Label("Dolby Atmos Version…", systemImage: "waveform")
                    }
                }

                Button {
                    showAddToPlaylist = true
                } label: {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
                .disabled(!isOnline)

                Divider()

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
            } preview: {
                SongContextPreview(coverImage: coverImage ?? loadedCoverImage, song: song)
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(song: song)
            }
            .sheet(isPresented: $showAtmosSelection) {
                AtmosVersionSelectionView(song: song)
            }
            .task(id: song.id) {
                // Preload persistent state and artwork while the row is idle, so the
                // long-press presentation performs no database or network work.
                pinnedSnapshot = await container?.pinService.isPinnedInBackground(itemType: .song, itemId: song.id) == true
                favoriteSnapshot = await container?.favoritesService.isFavoriteInBackground(itemType: .song, itemId: song.id) == true
                guard !Task.isCancelled else { return }
                guard coverImage == nil else { return }
                let artId = song.coverArtId ?? song.id
                if let cached = artworkImageCache.cachedImage(for: artId, tier: .thumb) {
                    loadedCoverImage = cached
                } else {
                    loadedCoverImage = await artworkImageCache.load(coverArtId: artId, tier: .thumb)
                }
            }
    }

    @ViewBuilder
    private var pinButton: some View {
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
                Label("Pin Song", systemImage: "pin")
            }
        }
    }

    private var shareText: String {
        [song.title, song.artist, song.albumName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private func toggleFavorite() {
        let wasFavorite = favoriteSnapshot
        favoriteSnapshot.toggle()
        Task {
            do {
                if wasFavorite {
                    try await container?.favoritesService.unstar(itemType: .song, itemId: song.id)
                } else {
                    try await container?.favoritesService.star(itemType: .song, itemId: song.id)
                }
            } catch {
                favoriteSnapshot = wasFavorite
            }
        }
    }
}

// MARK: - Collection context menu (albums and playlists)

/// Adds Play / Shuffle / Play Next / Add to Queue (when songs are provided),
/// Pin / Unpin, and Favorite (when favoriteType is non-nil) for albums and playlists.
/// `songs` defaults to empty — omit it on list rows where tracks aren't pre-loaded.
/// `favoriteType` is nil for playlists (Subsonic does not support playlist starring).
struct CollectionContextMenuModifier: ViewModifier {
    let itemType: PinnedItemType
    let itemId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?
    let coverImage: PlatformImage?
    let songs: [DisplayableSong]
    let favoriteType: FavoriteType?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    @Environment(\.appContainer) private var container
    @State private var showPinLimitAlert = false

    private var isPinned: Bool {
        container?.pinService.isPinned(itemType: itemType, itemId: itemId) == true
    }

    private var isFavorite: Bool {
        guard let ft = favoriteType else { return false }
        return container?.favoritesService.isFavorite(itemType: ft, itemId: itemId) == true
    }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: itemId, title: displayName)
            .contextMenu {
                ContextMenuShareAction(itemID: itemId, text: displayName)

                if !songs.isEmpty {
                    Button {
                        Task {
                            do {
                                try await container?.playerService.play(tracks: songs, startIndex: 0)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button {
                        let shuffled = songs.shuffled()
                        Task {
                            do {
                                try await container?.playerService.play(tracks: shuffled, startIndex: 0)
                            } catch {
                                Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                            }
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }

                    Button {
                        Task { await container?.playerService.playNext(songs) }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        Task { await container?.playerService.addToQueue(songs) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }

                    Divider()
                }

                Button {
                    playInstantMix(container: container, itemID: itemId, source: instantMixSource)
                } label: {
                    Label("Instant Mix", systemImage: "wand.and.stars")
                }

                Divider()

                if isPinned {
                    Button {
                        HapticFeedback.light.trigger()
                        container?.pinService.unpin(itemType: itemType, itemId: itemId)
                    } label: {
                        Label("Unpin from Home", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        guard let serverId = container?.serverState.activeServer?.id,
                              let pin = container?.pinService else { return }
                        do {
                            try pin.pin(
                                itemType: itemType, itemId: itemId,
                                displayName: displayName, displaySubtitle: displaySubtitle,
                                coverArtId: coverArtId, serverId: serverId
                            )
                            HapticFeedback.success.trigger()
                            container?.toastService.showConfirmation("Pinned to Home")
                        } catch PinError.limitReached {
                            HapticFeedback.warning.trigger()
                            showPinLimitAlert = true
                        } catch {
                            Logger.pin.error("ItemContextMenus: pin failed — \(error)")
                        }
                    } label: {
                        Label("Pin to Home", systemImage: "pin")
                    }
                }

                if favoriteType != nil {
                    Divider()

                    Button {
                        guard let ft = favoriteType else { return }
                        let fav = isFavorite
                        Task {
                            if fav {
                                try? await container?.favoritesService.unstar(itemType: ft, itemId: itemId)
                            } else {
                                try? await container?.favoritesService.star(itemType: ft, itemId: itemId)
                            }
                        }
                    } label: {
                        Label(
                            isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite ? "star.slash" : "star"
                        )
                    }
                }

                if onEdit != nil || onDelete != nil {
                    Divider()
                }

                if let onEdit {
                    Button { onEdit() } label: { Label("Edit Playlist", systemImage: "pencil") }
                }

                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: { Label("Delete Playlist", systemImage: "trash") }
                }
            } preview: {
                CollectionContextPreview(
                    coverImage: coverImage,
                    displayName: displayName,
                    displaySubtitle: displaySubtitle,
                    isArtist: itemType == .artist
                )
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
    }

    private var instantMixSource: JellyfinInstantMixSource {
        switch itemType {
        case .song: return .song
        case .album: return .album
        case .artist: return .artist
        case .playlist: return .playlist
        }
    }
}

// MARK: - Lazy collection context menu (albums without pre-loaded songs)

/// Like CollectionContextMenuModifier but fetches songs on-demand when a play action is tapped.
/// Use when tracks are not pre-loaded (e.g., Recently Added albums in HomeView).
struct LazyCollectionContextMenuModifier: ViewModifier {
    let itemType: PinnedItemType
    let itemId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?
    let coverImage: PlatformImage?
    let favoriteType: FavoriteType?
    let songLoader: () async throws -> [DisplayableSong]

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var showPinLimitAlert = false
    @State private var pinnedSnapshot = false
    @State private var favoriteSnapshot = false
    @State private var loadedCoverImage: PlatformImage?
    @State private var songsToAddToPlaylist: [DisplayableSong] = []
    @State private var showAddToPlaylist = false

    private var isPinned: Bool {
        pinnedSnapshot
    }

    private var isFavorite: Bool {
        favoriteSnapshot
    }

    func body(content: Content) -> some View {
        content
            .musicShareDraggable(itemID: itemId, title: displayName)
            .contextMenu {
                ControlGroup {
                    if favoriteType != nil {
                        Button {
                            toggleFavorite()
                        } label: {
                            Label(
                                isFavorite ? "Unfavorite" : "Favorite",
                                systemImage: isFavorite ? "star.fill" : "star"
                            )
                        }
                    }

                    ContextMenuShareAction(itemID: itemId, text: shareText)
                }

                Divider()

                Button {
                    Task {
                        guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                        do {
                            try await container?.playerService.play(tracks: songs, startIndex: 0)
                        } catch {
                            Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                        }
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }

                Button {
                    Task {
                        guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                        do {
                            try await container?.playerService.play(tracks: songs.shuffled(), startIndex: 0)
                        } catch {
                            Logger.player.error("[PLAYBACK] play failed: \(error, privacy: .public)")
                        }
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }

                Button {
                    playInstantMix(container: container, itemID: itemId, source: instantMixSource)
                } label: {
                    Label("Instant Mix", systemImage: "wand.and.stars")
                }

                Divider()

                if isPinned {
                    Button {
                        HapticFeedback.light.trigger()
                        container?.pinService.unpin(itemType: itemType, itemId: itemId)
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
                                itemType: itemType, itemId: itemId,
                                displayName: displayName, displaySubtitle: displaySubtitle,
                                coverArtId: coverArtId, serverId: serverId
                            )
                            pinnedSnapshot = true
                            HapticFeedback.success.trigger()
                            container?.toastService.showConfirmation("Pinned to Home")
                        } catch PinError.limitReached {
                            HapticFeedback.warning.trigger()
                            showPinLimitAlert = true
                        } catch {
                            Logger.pin.error("ItemContextMenus: pin failed — \(error)")
                        }
                    } label: {
                        Label("Pin to Home", systemImage: "pin")
                    }
                }

                if itemType == .album {
                    Button {
                        Task {
                            guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                            songsToAddToPlaylist = songs
                            showAddToPlaylist = true
                        }
                    } label: {
                        Label("Add to Playlist…", systemImage: "text.badge.plus")
                    }
                }

                Divider()

                Button {
                    Task {
                        guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                        await container?.playerService.playNext(songs)
                    }
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    Task {
                        guard let songs = try? await songLoader(), !songs.isEmpty else { return }
                        await container?.playerService.addToQueue(songs)
                    }
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
            } preview: {
                CollectionContextPreview(
                    coverImage: coverImage ?? loadedCoverImage,
                    displayName: displayName,
                    displaySubtitle: displaySubtitle,
                    isArtist: itemType == .artist
                )
            }
            .alert("Pin Limit Reached", isPresented: $showPinLimitAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PinError.limitReached.errorDescription ?? "")
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songs: songsToAddToPlaylist)
            }
            .task(id: "\(itemType.rawValue):\(itemId):\(coverArtId ?? "")") {
                // Snapshot persistent state before a press. Context-menu construction then
                // performs no SwiftData fetches and appears immediately.
                pinnedSnapshot = await container?.pinService.isPinnedInBackground(itemType: itemType, itemId: itemId) == true
                if let favoriteType {
                    favoriteSnapshot = await container?.favoritesService.isFavoriteInBackground(
                        itemType: favoriteType,
                        itemId: itemId
                    ) == true
                }
                guard !Task.isCancelled else { return }
                guard coverImage == nil else { return }
                let artId = coverArtId ?? itemId
                if let cached = artworkImageCache.cachedImage(for: artId, tier: .thumb) {
                    loadedCoverImage = cached
                } else {
                    loadedCoverImage = await artworkImageCache.load(coverArtId: artId, tier: .thumb)
                }
            }
    }

    private var shareText: String {
        displaySubtitle.isEmpty ? displayName : "\(displayName) — \(displaySubtitle)"
    }

    private var instantMixSource: JellyfinInstantMixSource {
        switch itemType {
        case .song: return .song
        case .album: return .album
        case .artist: return .artist
        case .playlist: return .playlist
        }
    }

    private func toggleFavorite() {
        guard let favoriteType else { return }
        let wasFavorite = favoriteSnapshot
        favoriteSnapshot.toggle()
        Task {
            do {
                if wasFavorite {
                    try await container?.favoritesService.unstar(itemType: favoriteType, itemId: itemId)
                } else {
                    try await container?.favoritesService.star(itemType: favoriteType, itemId: itemId)
                }
            } catch {
                favoriteSnapshot = wasFavorite
            }
        }
    }
}

@MainActor
func playInstantMix(container: AppContainer?, itemID: String, source: JellyfinInstantMixSource) {
    guard let container else { return }
    Task {
        do {
            let songs = try await container.jellyfinService.instantMix(
                canonicalItemID: itemID,
                source: source
            )
            guard !songs.isEmpty else {
                container.toastService.showError("No Instant Mix tracks were returned.")
                return
            }
            try await container.playerService.play(tracks: songs, startIndex: 0)
        } catch {
            Logger.player.error("Instant Mix failed: \(error.localizedDescription, privacy: .public)")
            container.toastService.showError("Instant Mix isn't available on this server.")
        }
    }
}

// MARK: - View extensions

extension View {
    func songContextMenu(song: DisplayableSong, coverImage: PlatformImage? = nil) -> some View {
        modifier(SongContextMenuModifier(song: song, coverImage: coverImage))
    }

    /// - Parameters:
    ///   - coverImage: Pre-loaded image from ArtworkImageCache. Pass nil to show a placeholder.
    ///   - songs: Pre-loaded tracks. Pass `[]` (default) on list rows to hide play actions.
    ///   - favoriteType: Pass `.album` for albums; `nil` for playlists (not supported by Subsonic).
    func collectionContextMenu(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String = "",
        coverArtId: String? = nil,
        coverImage: PlatformImage? = nil,
        songs: [DisplayableSong] = [],
        favoriteType: FavoriteType? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        modifier(CollectionContextMenuModifier(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            coverImage: coverImage,
            songs: songs,
            favoriteType: favoriteType,
            onEdit: onEdit,
            onDelete: onDelete
        ))
    }

    /// Variant for items where songs must be fetched on demand.
    /// `songLoader` is called lazily when a play action is tapped.
    func lazyCollectionContextMenu(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String = "",
        coverArtId: String? = nil,
        coverImage: PlatformImage? = nil,
        favoriteType: FavoriteType? = nil,
        songLoader: @escaping () async throws -> [DisplayableSong]
    ) -> some View {
        modifier(LazyCollectionContextMenuModifier(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            coverImage: coverImage,
            favoriteType: favoriteType,
            songLoader: songLoader
        ))
    }

    /// Long-press menu for albums: Play / Pin to Home / Favorite (loads tracks on demand).
    func albumLongPressMenu(_ album: AlbumID3) -> some View {
        modifier(AlbumLongPressMenuModifier(
            albumId: album.id,
            displayName: album.name,
            displaySubtitle: album.artist ?? "",
            coverArtId: album.coverArt
        ))
    }

    /// Long-press menu for albums identified by raw ids (downloaded / search history).
    func albumLongPressMenu(
        id: String,
        name: String,
        artist: String? = nil,
        coverArtId: String? = nil
    ) -> some View {
        modifier(AlbumLongPressMenuModifier(
            albumId: id,
            displayName: name,
            displaySubtitle: artist ?? "",
            coverArtId: coverArtId
        ))
    }

    /// Long-press menu for playlists: Play / Pin to Home (loads tracks on demand).
    func playlistLongPressMenu(
        id: String,
        name: String,
        coverArtId: String? = nil
    ) -> some View {
        modifier(PlaylistLongPressMenuModifier(
            playlistId: id,
            displayName: name,
            coverArtId: coverArtId
        ))
    }

    /// Long-press menu for artists: Play / Pin to Home / Favorite.
    func artistLongPressMenu(_ artist: ArtistID3) -> some View {
        modifier(ArtistLongPressMenuModifier(
            artistId: artist.id,
            displayName: artist.name,
            coverArtId: artist.coverArt
        ))
    }

    /// Long-press pin/play menu for a song tile (favorites shelf, etc.).
    func songLongPressMenu(_ song: DisplayableSong) -> some View {
        modifier(SongLongPressMenuModifier(song: song))
    }
}

// MARK: - Convenience long-press modifiers

private struct AlbumLongPressMenuModifier: ViewModifier {
    let albumId: String
    let displayName: String
    let displaySubtitle: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content.lazyCollectionContextMenu(
            itemType: .album,
            itemId: albumId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            favoriteType: .album,
            songLoader: {
                guard let c = container else { return [] }
                let loaded = try await c.libraryService.displayAlbum(id: albumId)
                return (loaded.song ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
            }
        )
    }
}

private struct PlaylistLongPressMenuModifier: ViewModifier {
    let playlistId: String
    let displayName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        content.lazyCollectionContextMenu(
            itemType: .playlist,
            itemId: playlistId,
            displayName: displayName,
            displaySubtitle: "",
            coverArtId: coverArtId,
            favoriteType: nil,
            songLoader: {
                guard let c = container else { return [] }
                let loaded = try await c.libraryService.playlist(id: playlistId)
                return (loaded.entry ?? []).map { DisplayableSong(from: $0, isDownloaded: false) }
            }
        )
    }
}

private struct ArtistLongPressMenuModifier: ViewModifier {
    let artistId: String
    let displayName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var coverImage: PlatformImage?

    func body(content: Content) -> some View {
        content
            .lazyCollectionContextMenu(
                itemType: .artist,
                itemId: artistId,
                displayName: displayName,
                displaySubtitle: "",
                coverArtId: coverArtId,
                coverImage: coverImage,
                favoriteType: .artist,
                songLoader: {
                    guard let c = container else { return [] }
                    let artist = try await c.libraryService.artist(id: artistId)
                    var songs: [DisplayableSong] = []
                    for album in (artist.album ?? []).prefix(5) {
                        let detail = try await c.libraryService.album(id: album.id)
                        songs.append(contentsOf: (detail.song ?? []).map { DisplayableSong(from: $0) })
                        if songs.count >= 40 { break }
                    }
                    return songs
                }
            )
            .task(id: coverArtId ?? artistId) {
                let id = coverArtId ?? artistId
                if let image = await artworkImageCache.load(coverArtId: id, tier: .hero) {
                    coverImage = image
                } else if let image = await artworkImageCache.load(coverArtId: id, tier: .thumb) {
                    coverImage = image
                }
            }
    }
}

private struct SongLongPressMenuModifier: ViewModifier {
    let song: DisplayableSong

    func body(content: Content) -> some View {
        content.songContextMenu(song: song)
    }
}
