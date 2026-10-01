// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import OSLog

/// Ephemeral “Made for You” mix detail — refreshes tracks on appear / pull / foreground.
struct PersonalMixDetailView: View {
    let kind: PersonalMixKind

    @Environment(\.appContainer) private var container
    @Environment(\.scenePhase) private var scenePhase
    @State private var mix: PersonalMix?
    @State private var isLoading = true
    @State private var songToAddToPlaylist: DisplayableSong?
    @State private var loadError: String?

    private var title: String {
        String(localized: String.LocalizationValue(kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: kind.gradientHexes.top),
                Color(hex: kind.gradientHexes.bottom)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, CassetteSpacing.l)
                    .padding(.top, CassetteSpacing.m)

                actionBar
                    .padding(.horizontal, CassetteSpacing.l)
                    .padding(.top, CassetteSpacing.l)
                    .padding(.bottom, CassetteSpacing.m)

                trackList
                    .padding(.horizontal, CassetteSpacing.l)
                    .padding(.bottom, CassetteSpacing.xl)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            gradient
                .opacity(0.22)
                .ignoresSafeArea()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayModeInline()
        .miniPlayerBottomMargin()
        .cassetteContentWidth()
        .task(id: kind) {
            await reload(forceRefresh: false)
        }
        .refreshable {
            await reload(forceRefresh: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reload(forceRefresh: true) }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.m) {
            RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous)
                .fill(gradient)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                        Text(title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        if let artists = mix?.artistNames, !artists.isEmpty {
                            Text(artists.joined(separator: ", "))
                                .font(.cassetteCaption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        } else if isLoading {
                            SkeletonBlock(width: 160, height: 14, cornerRadius: 4)
                        }
                    }
                    .padding(CassetteSpacing.l)
                }

            Text(String(localized: "Updates automatically based on your listening.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        let tracks = mix?.tracks ?? []
        return HStack(spacing: CassetteSpacing.m) {
            Button {
                HapticFeedback.medium.trigger()
                Task {
                    let shuffled = tracks.shuffled()
                    guard !shuffled.isEmpty else { return }
                    try? await container?.playerService.play(tracks: shuffled, startIndex: 0)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.cassetteCellTitle)
                    .cassetteGlassButton(size: 44)
            }
            .disabled(tracks.isEmpty)

            PlayButton(
                action: {
                    Task {
                        guard !tracks.isEmpty else { return }
                        try? await container?.playerService.play(tracks: tracks, startIndex: 0)
                    }
                },
                isDisabled: tracks.isEmpty
            )
            .frame(maxWidth: 220)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading, mix == nil {
            VStack(spacing: CassetteSpacing.s) {
                ForEach(0..<8, id: \.self) { _ in SkeletonSongRow() }
            }
            .allowsHitTesting(false)
        } else if let loadError, mix == nil {
            EmptyStateView(
                systemImage: "wifi.exclamationmark",
                title: String(localized: "Unable to Load", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: loadError,
                action: .init(label: String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Task { await reload(forceRefresh: true) }
                }
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if let mix, mix.tracks.isEmpty {
            EmptyStateView(
                systemImage: "music.note.list",
                title: String(localized: "No Songs Yet", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                subtitle: String(localized: "Keep listening and this mix will fill in.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if let mix {
            LazyVStack(spacing: 0) {
                ForEach(Array(mix.tracks.enumerated()), id: \.element.id) { index, song in
                    SongRow(
                        song: song,
                        index: index + 1,
                        showCoverArt: true,
                        onAddToPlaylist: { songToAddToPlaylist = $0 }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            try? await container?.playerService.play(
                                tracks: mix.tracks,
                                startIndex: index
                            )
                        }
                    }
                }
            }
        }
    }

    private func reload(forceRefresh: Bool) async {
        guard let container else { return }
        if mix == nil { isLoading = true }
        loadError = nil
        let serverId = container.serverState.activeServer?.id.uuidString
        let result = await container.personalMixService.mix(
            kind: kind,
            serverId: serverId,
            forceRefresh: forceRefresh
        )
        mix = result
        if result == nil {
            loadError = String(localized: "Couldn’t build this mix right now.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        isLoading = false
    }
}
