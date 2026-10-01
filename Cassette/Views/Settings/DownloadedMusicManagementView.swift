// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftData
import SwiftUI

/// Apple Music–style storage browser for permanent offline downloads.
///
/// SwiftData content cannot be rendered by a static settings plist, so this screen lives in
/// Cassette's Storage settings while preserving the same All Songs → Artist → Album hierarchy.
struct DownloadedMusicManagementView: View {
    @Environment(\.appContainer) private var container
    @Query private var downloadedTracks: [DownloadedTrack]

    private var tracks: [ManagedDownloadTrack] {
        downloadedTracks.map(ManagedDownloadTrack.init).sorted(by: ManagedDownloadTrack.areInDefaultOrder)
    }

    private var artists: [ManagedDownloadArtist] {
        ManagedDownloadLibrary.artists(from: tracks)
    }

    private var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Downloaded Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    systemImage: "arrow.down.circle",
                    description: Text(String(localized: "Music downloaded for offline listening will appear here.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                )
            } else {
                List {
                    Section {
                        ForEach([DownloadedMusicSummary.allSongs]) { _ in
                            NavigationLink {
                                DownloadedSongsManagementView(
                                    title: String(localized: "All Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    trackIDs: nil
                                )
                            } label: {
                                DownloadedMusicSimpleRow(
                                    title: String(localized: "All Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                    byteCount: totalBytes
                                )
                            }
                        }
                        .onDelete { _ in delete(tracks) }
                    } header: {
                        DownloadedMusicSectionHeader(
                            title: String(localized: "Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            byteCount: totalBytes
                        )
                    }

                    Section {
                        ForEach(artists) { artist in
                            NavigationLink {
                                DownloadedArtistManagementView(artistID: artist.id, title: artist.name)
                            } label: {
                                DownloadedMusicArtworkRow(
                                    coverArtId: artist.coverArtId,
                                    fallbackId: artist.id,
                                    circular: true,
                                    title: artist.name,
                                    subtitle: artist.subtitle,
                                    byteCount: artist.byteCount
                                )
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.compactMap { artists.indices.contains($0) ? artists[$0].tracks : nil }.flatMap { $0 })
                        }
                    } header: {
                        DownloadedMusicSectionHeader(
                            title: String(localized: "Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            byteCount: totalBytes
                        )
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .modifier(SettingsSubpageStyle())
            }
        }
        .navigationTitle(String(localized: "Downloaded Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            if !tracks.isEmpty { EditButton() }
            #endif
        }
    }

    private func delete(_ tracks: [ManagedDownloadTrack]) {
        guard let downloadService = container?.downloadService else { return }
        Task {
            for track in tracks {
                try? await downloadService.remove(songId: track.songId, serverId: track.serverId)
            }
        }
    }
}

private struct DownloadedArtistManagementView: View {
    @Environment(\.appContainer) private var container
    @Query private var downloadedTracks: [DownloadedTrack]
    let artistID: String
    let title: String

    private var tracks: [ManagedDownloadTrack] {
        downloadedTracks
            .map(ManagedDownloadTrack.init)
            .filter { ManagedDownloadLibrary.artistKey($0) == artistID }
            .sorted(by: ManagedDownloadTrack.areInDefaultOrder)
    }

    private var albums: [ManagedDownloadAlbum] {
        ManagedDownloadLibrary.albums(from: tracks)
    }

    var body: some View {
        List {
            Section {
                ForEach(albums) { album in
                    NavigationLink {
                        DownloadedSongsManagementView(
                            title: album.name,
                            trackIDs: Set(album.tracks.map(\.id))
                        )
                    } label: {
                        DownloadedMusicArtworkRow(
                            coverArtId: album.coverArtId,
                            fallbackId: album.id,
                            circular: false,
                            title: album.name,
                            subtitle: CassetteCountLabel.songs(album.tracks.count),
                            byteCount: album.byteCount
                        )
                    }
                }
                .onDelete { offsets in
                    let selected = offsets.compactMap { albums.indices.contains($0) ? albums[$0] : nil }
                    delete(selected.flatMap(\.tracks))
                }
            } header: {
                DownloadedMusicSectionHeader(
                    title: String(localized: "Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    byteCount: tracks.reduce(0) { $0 + $1.fileSize }
                )
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .modifier(SettingsSubpageStyle())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func delete(_ tracks: [ManagedDownloadTrack]) {
        guard let downloadService = container?.downloadService else { return }
        Task {
            for track in tracks {
                try? await downloadService.remove(songId: track.songId, serverId: track.serverId)
            }
        }
    }
}

private struct DownloadedSongsManagementView: View {
    @Environment(\.appContainer) private var container
    @Query private var downloadedTracks: [DownloadedTrack]
    let title: String
    let trackIDs: Set<String>?

    private var tracks: [ManagedDownloadTrack] {
        downloadedTracks
            .map(ManagedDownloadTrack.init)
            .filter { trackIDs?.contains($0.id) ?? true }
            .sorted(by: ManagedDownloadTrack.areInDefaultOrder)
    }

    var body: some View {
        List {
            Section {
                ForEach(tracks) { track in
                    DownloadedMusicArtworkRow(
                        coverArtId: track.coverArtId,
                        fallbackId: track.songId,
                        circular: false,
                        title: track.title,
                        subtitle: track.artist,
                        byteCount: track.fileSize,
                        showsChevron: false
                    )
                }
                .onDelete { offsets in
                    delete(offsets.compactMap { tracks.indices.contains($0) ? tracks[$0] : nil })
                }
            } header: {
                DownloadedMusicSectionHeader(
                    title: String(localized: "Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    byteCount: tracks.reduce(0) { $0 + $1.fileSize }
                )
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .modifier(SettingsSubpageStyle())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func delete(_ tracks: [ManagedDownloadTrack]) {
        guard let downloadService = container?.downloadService else { return }
        Task {
            for track in tracks {
                try? await downloadService.remove(songId: track.songId, serverId: track.serverId)
            }
        }
    }
}

private struct DownloadedMusicSectionHeader: View {
    let title: String
    let byteCount: Int64

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(ManagedDownloadLibrary.formatted(byteCount))
        }
        .textCase(nil)
    }
}

private struct DownloadedMusicSimpleRow: View {
    let title: String
    let byteCount: Int64

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(ManagedDownloadLibrary.formatted(byteCount))
                .foregroundStyle(.secondary)
        }
        .font(.body)
        .padding(.vertical, 5)
    }
}

private struct DownloadedMusicArtworkRow: View {
    let coverArtId: String?
    let fallbackId: String
    let circular: Bool
    let title: String
    let subtitle: String?
    let byteCount: Int64
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            CoverArtCard(
                id: coverArtId ?? fallbackId,
                size: 48,
                cornerRadius: circular ? 24 : 6
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            Text(ManagedDownloadLibrary.formatted(byteCount))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

nonisolated private enum DownloadedMusicSummary: String, Identifiable {
    case allSongs
    var id: String { rawValue }
}

nonisolated private struct ManagedDownloadTrack: Identifiable, Hashable {
    let songId: String
    let serverId: UUID
    let albumId: String?
    let title: String
    let artist: String
    let artistId: String?
    let album: String
    let trackNumber: Int?
    let coverArtId: String?
    let fileSize: Int64

    var id: String { "\(serverId.uuidString):\(songId)" }

    init(_ track: DownloadedTrack) {
        songId = track.songId
        serverId = track.serverId
        albumId = track.albumId
        title = track.title
        artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "Unknown Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        artistId = track.artistId
        album = track.album?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "Unknown Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        trackNumber = track.trackNumber
        coverArtId = track.coverArtId
        fileSize = track.fileSize
    }

    static func areInDefaultOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        let albumOrder = lhs.album.localizedStandardCompare(rhs.album)
        if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
        if lhs.trackNumber != rhs.trackNumber {
            return (lhs.trackNumber ?? Int.max) < (rhs.trackNumber ?? Int.max)
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

nonisolated private struct ManagedDownloadAlbum: Identifiable {
    let id: String
    let name: String
    let coverArtId: String?
    let tracks: [ManagedDownloadTrack]
    var byteCount: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
}

nonisolated private struct ManagedDownloadArtist: Identifiable {
    let id: String
    let name: String
    let coverArtId: String?
    let tracks: [ManagedDownloadTrack]
    let subtitle: String
    var byteCount: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
}

nonisolated private enum ManagedDownloadLibrary {
    static func artists(from tracks: [ManagedDownloadTrack]) -> [ManagedDownloadArtist] {
        Dictionary(grouping: tracks, by: artistKey)
            .map { key, group in
                let albums = self.albums(from: group)
                return ManagedDownloadArtist(
                    id: key,
                    name: group.first?.artist ?? "",
                    coverArtId: group.compactMap(\.coverArtId).first,
                    tracks: group,
                    subtitle: albums.count == 1
                        ? (albums.first?.name ?? "")
                        : CassetteCountLabel.albums(albums.count)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func albums(from tracks: [ManagedDownloadTrack]) -> [ManagedDownloadAlbum] {
        Dictionary(grouping: tracks, by: albumKey)
            .map { key, group in
                ManagedDownloadAlbum(
                    id: key,
                    name: group.first?.album ?? "",
                    coverArtId: group.compactMap(\.coverArtId).first,
                    tracks: group.sorted(by: ManagedDownloadTrack.areInDefaultOrder)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func formatted(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func artistKey(_ track: ManagedDownloadTrack) -> String {
        let identity = track.artistId?.nilIfEmpty ?? track.artist.lowercased()
        return "\(track.serverId.uuidString):\(identity)"
    }

    private static func albumKey(_ track: ManagedDownloadTrack) -> String {
        let identity = track.albumId?.nilIfEmpty ?? track.album.lowercased()
        return "\(track.serverId.uuidString):\(identity)"
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
