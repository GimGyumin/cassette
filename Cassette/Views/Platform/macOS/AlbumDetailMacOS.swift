// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftData
import SwiftSonic

struct AlbumDetailMacOS: View {
    let albumId: String
    let albumName: String
    let coverArtId: String?
    var showBackButton: Bool = true

    init(albumId: String, albumName: String, coverArtId: String? = nil, showBackButton: Bool = true) {
        self.albumId = albumId
        self.albumName = albumName
        self.coverArtId = coverArtId
        self.showBackButton = showBackButton
        let itemId = albumId
        let type = FavoriteType.album.rawValue
        _albumFavoriteMatches = Query(filter: #Predicate<FavoriteRecord> {
            $0.itemId == itemId && $0.itemType == type
        })
    }

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AlbumDetailViewModel?
    @State private var songToAddToPlaylist: DisplayableSong?
    @State private var showDeleteDownloadAlert = false
    @State private var showFullDescription = false
    @Query private var albumFavoriteMatches: [FavoriteRecord]

    private var isAlbumFavorite: Bool {
        guard let serverId = container?.serverState.activeServer?.id else { return false }
        return albumFavoriteMatches.contains { $0.serverId == serverId }
    }

    var body: some View {
        Group {
            if let vm {
                albumContent(vm)
            } else {
                LoadingStateView()
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { albumToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .alert("Remove downloaded album?", isPresented: $showDeleteDownloadAlert) {
            Button("Remove", role: .destructive) { Task { await vm?.deleteDownload() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The audio files will be deleted from this device.")
        }
        .sheet(isPresented: $showFullDescription) {
            NavigationStack {
                ScrollView {
                    Text(vm?.albumDescription ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("About")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showFullDescription = false }
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 320)
        }
        .task(id: container?.serverState.isOnline) {
            guard let c = container else { return }
            if vm == nil {
                vm = AlbumDetailViewModel(
                    albumId: albumId,
                    libraryService: c.libraryService,
                    downloadService: c.downloadService,
                    toastService: c.toastService,
                    serverState: c.serverState
                )
            }
            await vm?.load()
            await vm?.loadMoreAlbumsByArtist()
        }
    }

    private func albumContent(_ vm: AlbumDetailViewModel) -> some View {
        let songs = vm.songs
        let serverId = container?.serverState.activeServer?.id ?? UUID()
        return List {
            DetailHeroView(
                coverArtId: vm.coverArtId ?? coverArtId,
                title: vm.albumName.isEmpty ? albumName : vm.albumName,
                primaryLine: vm.artistName,
                secondaryLine: secondaryLine(vm: vm),
                onPrimaryLineTap: artistTapAction(vm),
                quality: AudioQualityClassifier.bestQuality(in: songs),
                audioFormat: songs.compactMap(\.audioFormat).first,
                primaryAction: {
                    Task { try? await container?.playerService.play(tracks: songs, startIndex: 0) }
                },
                secondaryAction: {
                    Task {
                        let startIndex = songs.isEmpty ? 0 : Int.random(in: 0..<songs.count)
                        try? await container?.playerService.play(tracks: songs, startIndex: startIndex)
                        if container?.playerState.isShuffled != true {
                            await container?.playerService.toggleShuffle()
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if vm.isDownloadingAlbum {
                albumDownloadProgress(vm)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let description = vm.albumDescription, !description.isEmpty {
                Button { showFullDescription = true } label: {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if vm.isLoading && songs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if songs.isEmpty, let error = vm.error {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Unable to Load Album",
                    subtitle: error.displayMessage,
                    action: .init(label: "Retry") { Task { await vm.load() } }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                AlbumSongRows(
                    songs: songs,
                    albumId: albumId,
                    serverId: serverId,
                    albumArtist: vm.artistName,
                    downloadingIds: vm.downloadingIds,
                    onTap: { index in
                        Task { try? await container?.playerService.play(tracks: songs, startIndex: index) }
                    },
                    onDownload: (vm.isOffline || vm.isDownloadingAlbum) ? nil : { songId in
                        Task { await vm.downloadSong(id: songId) }
                    },
                    onRemoveDownload: { songId in
                        Task { try? await container?.downloadService.remove(songId: songId, serverId: serverId) }
                    },
                    onAddToPlaylist: { song in songToAddToPlaylist = song }
                )
            }

            if !vm.otherAlbumVersions.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(vm.otherAlbumVersions) { album in
                                NavigationLink(value: HomeDestination.album(album)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverArtView(id: album.coverArt ?? album.id, size: 200)
                                            .frame(width: 120, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(album.name)
                                            .font(.cassetteCellTitle)
                                            .lineLimit(2)
                                        if let subtitle = AlbumVersionMatcher.editionSubtitle(for: album) {
                                            Text(subtitle)
                                                .font(.cassetteCaption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(width: 120, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .albumLongPressMenu(album)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                } header: {
                    Text(String(localized: "Other Versions", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }
            }

            if !vm.moreAlbumsByArtist.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(vm.moreAlbumsByArtist) { album in
                                NavigationLink(value: HomeDestination.album(album)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CoverArtView(id: album.coverArt ?? album.id, size: 200)
                                            .frame(width: 120, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(album.name)
                                            .font(.cassetteCellTitle)
                                            .lineLimit(2)
                                        if let year = album.year {
                                            Text(verbatim: "\(year)")
                                                .font(.cassetteCaption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 120, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .albumLongPressMenu(album)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                } header: {
                    Text(moreByTitle(vm: vm))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await vm.load()
            await vm.loadMoreAlbumsByArtist()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: CassetteMacOSLayout.playerBarReservedHeight / 2)
        }
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    private func albumDownloadProgress(_ vm: AlbumDetailViewModel) -> some View {
        let total = max(vm.songs.count, 1)
        let downloaded = vm.songs.filter(\.isDownloaded).count
        return VStack(alignment: .leading, spacing: 4) {
            if downloaded == 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting download…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: Double(downloaded), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(Color.cassetteAccent)
                Text("Downloading \(downloaded)/\(total) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func artistTapAction(_ vm: AlbumDetailViewModel) -> (() -> Void)? {
        guard let artistId = vm.artistId, let name = vm.artistName else { return nil }
        return {
            // Navigate via the root NavigationStack destination map.
            NotificationCenter.default.post(
                name: .cassetteNavigateToArtist,
                object: nil,
                userInfo: [
                    "artistId": artistId,
                    "artistName": name,
                    "coverArtId": coverArtId as Any
                ]
            )
        }
    }

    private func secondaryLine(vm: AlbumDetailViewModel) -> String? {
        var parts: [String] = []
        if let year = vm.year { parts.append(String(year)) }
        if let genre = vm.genre { parts.append(genre) }
        let count = vm.songCount > 0 ? vm.songCount : vm.songs.count
        if count > 0 { parts.append(String(localized: "\(count) tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func moreByTitle(vm: AlbumDetailViewModel) -> String {
        if let artist = vm.artistName, !artist.isEmpty {
            return String(localized: "More by \(artist)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(localized: "More by This Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private func downloadState(for vm: AlbumDetailViewModel) -> MacAlbumDownloadState {
        let total = vm.songs.count
        guard total > 0 else { return .notDownloaded }
        let downloaded = vm.songs.filter(\.isDownloaded).count
        if downloaded == 0 { return .notDownloaded }
        if downloaded == total { return .fullyDownloaded }
        return .partiallyDownloaded
    }

    @ToolbarContentBuilder
    private var albumToolbar: some ToolbarContent {
        if showBackButton {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .cassetteGlassButton(size: 28)
                }
                .buttonStyle(.borderless)
                .help("Back")
            }
            .cassetteSharedBackgroundVisibility(.hidden)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                let wasFavorite = isAlbumFavorite
                Task {
                    guard let container else { return }
                    do {
                        if wasFavorite {
                            try await container.favoritesService.unstar(itemType: .album, itemId: albumId)
                        } else {
                            try await container.favoritesService.star(itemType: .album, itemId: albumId)
                        }
                    } catch {
                        container.toastService.showError(error.localizedDescription)
                    }
                }
            } label: {
                Image(systemName: isAlbumFavorite ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAlbumFavorite ? Color.cassetteAccent : .primary)
                    .cassetteGlassButton(size: 28)
            }
            .buttonStyle(.borderless)
            .disabled(container?.serverState.isOnline != true)
            .help(isAlbumFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .cassetteSharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            if vm?.isDownloadingAlbum == true {
                Button {
                    Task { await vm?.cancelAlbumDownload() }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .cassetteGlassButton(size: 28)
                }
                .buttonStyle(.borderless)
                .help("Cancel Download")
            } else if let vm, vm.isOffline != true {
                switch downloadState(for: vm) {
                case .notDownloaded:
                    Button {
                        Task { await vm.downloadAlbum() }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .cassetteGlassButton(size: 28)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.songs.isEmpty || container?.serverState.isOnline != true)
                    .help("Download Album")
                case .partiallyDownloaded:
                    Button {
                        Task { await vm.downloadMissingTracks() }
                    } label: {
                        Image(systemName: "arrow.down.circle.dotted")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .cassetteGlassButton(size: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Download Missing Tracks")
                case .fullyDownloaded:
                    Button {
                        showDeleteDownloadAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .cassetteGlassButton(size: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Download")
                }
            }
        }
        .cassetteSharedBackgroundVisibility(.hidden)
    }
}

private enum MacAlbumDownloadState {
    case notDownloaded, partiallyDownloaded, fullyDownloaded
}
#endif
