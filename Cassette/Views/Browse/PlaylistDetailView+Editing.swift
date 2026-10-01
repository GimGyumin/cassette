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
    // MARK: - In-place edit header (iOS in-place editor; reuses the validated carousel + fields)

    var editHeader: some View {
        VStack(spacing: CassetteSpacing.xl) {
            editCoverCarousel
                // Clear the (edit-mode) nav bar since the list bleeds under it via ignoresSafeArea(.top).
                .padding(.top, 100)
            VStack(spacing: CassetteSpacing.s) {
                TextField("Playlist Title", text: $editName)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, CassetteSpacing.s)
                TextField("Description", text: $editComment, axis: .vertical)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...4)

                Picker("Visibility", selection: $editIsPublic) {
                    Label("Private", systemImage: "lock.fill").tag(false)
                    Label("Public", systemImage: "globe").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.top, CassetteSpacing.s)
            }
            .padding(.horizontal, CassetteSpacing.l)
        }
        .padding(.bottom, CassetteSpacing.l)
    }

    private var editCoverCarousel: some View {
        PlaylistCoverCarousel(
            title: editName,
            selectedGradient: selectedGradient,
            isPhotoSelected: photoIsCover,
            photoPreview: editPhotoPreview,
            showsPhotoOption: editShowsPhotoOption,
            leadingLabel: "Current",
            leadingCoverArtId: effectiveCoverArtId,
            onSelectLeading: {
                selectedGradient = nil
                photoIsCover = false
                coverDirty = true
            },
            onSelectPhoto: {
                selectedGradient = nil
                photoIsCover = true
                coverDirty = true
            },
            onRequestPhotoPicker: {
                selectedGradient = nil
                photoIsCover = true
                coverDirty = true
                #if os(iOS)
                showImageOptions = true
                #endif
            },
            onSelectGradient: { shape in
                selectedGradient = shape
                photoIsCover = false
                coverDirty = true
            }
        )
    }

    private var editShowsPhotoOption: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var editPhotoPreview: PlatformImage? {
        #if os(iOS)
        return pendingImage
        #else
        return nil
        #endif
    }

    /// Enter in-place edit: snapshot the current metadata + cover choice into the working edit state, animate in.
    func enterEdit() {
        editName = viewModel?.name ?? initialName
        editComment = viewModel?.playlistDetail?.comment ?? ""
        editIsPublic = viewModel?.playlistDetail?.isPublic == true
        editSongs = resolvedSongs(viewModel)
        selectedSongIds = []
        selectedGradient = nil
        photoIsCover = false
        coverDirty = false
        #if os(iOS)
        pendingImage = nil
        #endif
        loadEditGradientChoice()
        withAnimation(CassetteAnimation.surface) { isEditing = true }
    }

    /// Cancel in-place edit: discard the working state without mutating anything.
    func cancelEdit() {
        withAnimation(CassetteAnimation.surface) { isEditing = false }
    }

    /// Commit in-place edit: the SAME mutation sequence as EditPlaylistSheet.commit() — rename, the atomic
    /// full-list replace (reorder + multi-remove), the R1 comment re-assert, the cover apply, and the
    /// first-track color derivation — then refresh the detail view and animate back to view mode.
    func commitEdit() async {
        guard let c = container, let serverId = c.serverState.activeServer?.id else {
            withAnimation(CassetteAnimation.surface) { isEditing = false }
            return
        }
        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = editComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentName = viewModel?.name ?? initialName
        let currentComment = viewModel?.playlistDetail?.comment ?? ""
        let currentIsPublic = viewModel?.playlistDetail?.isPublic == true
        let commentChanged = trimmedComment != currentComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSongs = resolvedSongs(viewModel)
        let songsChanged = editSongs.map(\.id) != originalSongs.map(\.id)

        if !trimmedName.isEmpty && trimmedName != currentName.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? await c.playlistService.renamePlaylist(id: playlistId, newName: trimmedName)
        }
        if editIsPublic != currentIsPublic {
            try? await c.playlistService.updateVisibility(id: playlistId, isPublic: editIsPublic)
        }
        // Atomic full-list replace — the single track-mutation path (reorder + multi-select remove).
        if songsChanged {
            try? await c.playlistService.reorderTracks(playlistId: playlistId, orderedSongIds: editSongs.map(\.id))
        }
        // R1 guard: re-assert a non-empty comment after the replace (it doesn't survive createPlaylist); always
        // write a changed comment. One write covers the guard + a description edit. NO name re-assert.
        if (songsChanged && !trimmedComment.isEmpty) || commentChanged {
            try? await c.playlistService.updateDescription(id: playlistId, description: trimmedComment)
        }
        if coverDirty {
            await applyCoverInPlace(container: c, serverId: serverId, originalSongs: originalSongs)
        }
        // First-track derivation: empty→first-track fills the gradient color (frozen after). Runs after
        // applyCover so a simultaneous re-pick (resolved from the OLD empty first track) is corrected.
        await AddMusicCommitter.deriveFirstTrackCoverIfNeeded(
            wasEmpty: originalSongs.isEmpty,
            firstSong: editSongs.first,
            playlistId: playlistId,
            serverId: serverId,
            container: c,
            colorExtractor: colorExtractor
        )
        await viewModel?.load()
        coverRefreshID = UUID()
        withAnimation(CassetteAnimation.surface) { isEditing = false }
    }

    func setPlaylistVisibility(_ isPublic: Bool) async {
        guard let c = container else { return }
        do {
            try await c.playlistService.updateVisibility(id: playlistId, isPublic: isPublic)
            await viewModel?.load()
            HapticFeedback.success.trigger()
            c.toastService.showConfirmation(isPublic ? "Playlist is now public" : "Playlist is now private")
        } catch {
            Logger.playlist.error("Failed to update playlist visibility: \(error.localizedDescription, privacy: .public)")
            c.toastService.showError("Could not update playlist visibility")
        }
    }

    private func applyCoverInPlace(container c: AppContainer, serverId: UUID, originalSongs: [DisplayableSong]) async {
        let manager = PlaylistCoverManager(
            serverState: c.serverState,
            serverService: c.serverService,
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        let store = PlaylistCoverStore(modelContainer: c.modelContainer)
        if let shape = selectedGradient {
            // Re-pick → resolve the color from the CURRENT first track (neutral if the playlist is empty).
            let spec = await PlaylistGradientResolver.resolve(
                form: shape,
                firstTrackCoverArtId: originalSongs.first?.coverArtId,
                artworkImageCache: c.artworkImageCache,
                colorExtractor: colorExtractor
            )
            await manager.applyGradientCover(spec, playlistId: playlistId)
            store.save(spec, playlistId: playlistId, serverId: serverId, isUserPicked: true)
            return
        }
        #if os(iOS)
        if photoIsCover, let image = pendingImage, let data = image.jpegData(compressionQuality: 0.85) {
            await manager.applyImageCover(data, playlistId: playlistId)
            // A photo supersedes any gradient choice → drop the stored gradient.
            store.remove(playlistId: playlistId, serverId: serverId)
        }
        #endif
    }

    // MARK: - In-place editable track list (Gate 2 — mirrors the edit sheet's reorder + multi-select remove)

    @ViewBuilder
    var editableSongRows: some View {
        ForEach(editSongs) { song in
            editTrackRow(song)
                .tag(song.id)
                .listRowBackground(bodyColor)
                .environment(\.colorScheme, dragHandleScheme)
        }
        .onMove { from, to in
            editSongs.move(fromOffsets: from, toOffset: to)
        }
    }

    /// Force the editable rows' color scheme to the theme's luminance so the SYSTEM reorder handles (≡) and
    /// selection circles contrast the themed row background — they render system-grey (low contrast) otherwise.
    /// The rows' own text uses explicit theme colors, so it is unaffected.
    private var dragHandleScheme: ColorScheme {
        atmosphere.preferredColorScheme ?? colorScheme
    }

    private func editTrackRow(_ song: DisplayableSong) -> some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtView(id: song.coverArtId ?? song.id, size: 80, cornerRadius: CassetteCornerRadius.standard)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.cassetteCellTitle)
                    .foregroundStyle(headerTextColor)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.cassetteCellSubtitle)
                        .foregroundStyle(headerSecondaryColor)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Multi-select remove: drop the selected tracks from the local working list. NO per-index server delete —
    /// the commit (Gate 3) replaces the whole list atomically (final list = editSongs − selection), so it's
    /// immune to index drift. Mirrors the edit sheet's removeSelectedTracks (Gate B).
    func removeSelectedTracks() {
        editSongs.removeAll { selectedSongIds.contains($0.id) }
        selectedSongIds.removeAll()
    }

    func deletePlaylistInPlace(purgeDownloads: Bool) async {
        guard let c = container else { return }
        do {
            try await c.playlistService.deletePlaylist(id: playlistId, purgeDownloads: purgeDownloads)
            postPlaylistDeleted()
            dismiss()
        } catch {
            Logger.playlist.error("PlaylistDetailView: in-place delete failed: \(error, privacy: .public)")
            c.toastService.showError("Failed to delete playlist")
        }
    }

    private func loadEditGradientChoice() {
        guard let c = container, let serverId = c.serverState.activeServer?.id else { return }
        if let choice = PlaylistCoverStore(modelContainer: c.modelContainer).choice(playlistId: playlistId, serverId: serverId),
           choice.isUserPicked, let spec = choice.spec {
            selectedGradient = spec.shape
        }
    }

    #if os(iOS)
    /// Defer presenting the crop screen so the picker fully dismisses first (sequential full-screen covers).
    func presentCrop(_ image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            imageToCrop = CroppableImage(image: image)
        }
    }
    #endif
}
