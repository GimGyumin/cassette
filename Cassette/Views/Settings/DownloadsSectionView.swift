// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import OSLog
import SwiftUI

struct DownloadsSectionView: View {
    let vm: DownloadsViewModel

    var body: some View {
        Section {
            LabeledContent {
                Text(vm.usedBytesFormatted)
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    Text("Used")
                } icon: {
                    SettingsIcon(systemImage: "arrow.down.circle.fill", color: .green)
                }
            }

            if !vm.displayAlbums.isEmpty {
                DisclosureGroup {
                    ForEach(vm.displayAlbums) { album in
                        HStack(spacing: CassetteSpacing.m) {
                            CoverArtCard(id: album.coverArtId ?? album.albumId, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let total = album.totalTracksCount {
                                    Text(String(format: String(localized: "%lld/%lld tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Int64(album.downloadedTracksCount), Int64(total)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: String(localized: "%lld tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Int64(album.downloadedTracksCount)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.removeAlbum(album) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    Label {
                        Text(String(format: String(localized: "Albums (%lld)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Int64(vm.displayAlbums.count)))
                    } icon: {
                        SettingsIcon(systemImage: "music.note.list", color: Color.cassetteAccent)
                    }
                }
            }

            if !vm.downloadedPlaylists.isEmpty {
                DisclosureGroup {
                    ForEach(vm.downloadedPlaylists) { playlist in
                        HStack(spacing: CassetteSpacing.m) {
                            CoverArtCard(id: playlist.playlistId, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(String(format: String(localized: "%lld/%lld tracks", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Int64(playlist.tracksCount), Int64(playlist.totalTracksCount)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.removePlaylist(playlist) }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } label: {
                    Label {
                        Text(String(format: String(localized: "Playlists (%lld)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Int64(vm.downloadedPlaylists.count)))
                    } icon: {
                        SettingsIcon(systemImage: "list.bullet", color: CassetteColors.accent)
                    }
                }
            }

            if vm.displayAlbums.isEmpty && vm.downloadedPlaylists.isEmpty {
                Text("No downloaded content.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Button(role: .destructive) {
                Task { await vm.clearAll() }
            } label: {
                if vm.isClearingAll {
                    HStack(spacing: CassetteSpacing.s) {
                        ProgressView().scaleEffect(0.8)
                        Text("Clearing…")
                    }
                } else {
                    SettingsRowLabel(title: "Clear all downloads", systemImage: "trash.fill", color: .red)
                }
            }
            .disabled(vm.isClearingAll || (vm.displayAlbums.isEmpty && vm.downloadedPlaylists.isEmpty))

        } header: {
            SettingsSectionHeader("Downloads")
        } footer: {
            Text("Downloaded tracks are stored permanently until you remove them.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteDownloadCompleted)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            Task { await vm.loadData() }
        }
    }
}
