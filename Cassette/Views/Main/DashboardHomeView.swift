// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

/// Home tab — recommendations and listening activity at a glance.
/// Horizontal “Made for You” / album shelves on all size classes.
struct DashboardHomeView: View {
    @Environment(\.appContainer) private var container
    @State private var vm: DiscoverViewModel?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CassetteSpacing.xl) {
                greetingHeader
                if let vm {
                    if vm.isErrorState {
                        EmptyStateView(
                            systemImage: "wifi.exclamationmark",
                            title: String(localized: "Unable to Load", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            subtitle: String(localized: "Check your connection and try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            action: .init(label: String(localized: "Retry", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                Task { await reload(forceRefresh: true) }
                            }
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else if vm.isInitialLoading {
                        homeSkeletonShelves
                    } else {
                        if !vm.personalMixes.isEmpty {
                            PersonalMixShelf(mixes: vm.personalMixes)
                        }
                        if !vm.recentlyPlayed.isEmpty {
                            AdaptiveAlbumShelf(
                                title: String(localized: "Recently Played", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                albums: vm.recentlyPlayed,
                                showArtist: true
                            )
                        }
                        if !vm.mostPlayed.isEmpty {
                            AdaptiveAlbumShelf(
                                title: String(localized: "Frequently Played", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                albums: vm.mostPlayed,
                                showArtist: true
                            )
                        }
                        if !vm.suggestedSelection.isEmpty {
                            AdaptiveAlbumShelf(
                                title: String(localized: "Suggested Selection", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                albums: vm.suggestedSelection,
                                showArtist: true
                            )
                        }
                    }
                } else {
                    homeSkeletonShelves
                }
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.vertical, CassetteSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Home", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .cassetteAccountProfileToolbar()
        .cassetteContentWidth(.fill)
        .task {
            guard let container else { return }
            let serverId = container.serverState.activeServer?.id.uuidString
            if vm == nil {
                vm = DiscoverViewModel(
                    libraryService: container.libraryService,
                    recommendationService: container.recommendationService,
                    personalMixService: container.personalMixService,
                    serverId: serverId
                )
                // Cached content is already applied in init — unlock deferred boot work immediately.
                if DiscoverSectionsCache.hasContent {
                    AppBootGate.markHomeReady()
                }
            }
            await vm?.loadHomeDashboard(serverId: serverId)
        }
        .refreshable {
            await reload(forceRefresh: true)
        }
    }

    private func reload(forceRefresh: Bool) async {
        let serverId = container?.serverState.activeServer?.id.uuidString
        await vm?.loadHomeDashboard(forceRefresh: forceRefresh, serverId: serverId)
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text(String(localized: "Listen Now", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteDetailTitle)
            Text(String(localized: "Pick up where you left off or explore something new.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homeSkeletonShelves: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xl) {
            skeletonMixShelf
            skeletonShelf(title: String(localized: "Recently Played", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            skeletonShelf(title: String(localized: "Frequently Played", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            skeletonShelf(title: String(localized: "Suggested Selection", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
        .allowsHitTesting(false)
        .accessibilityLabel(String(localized: "Loading", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    private func skeletonShelf(title: String) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(title)
                .font(.cassetteSectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CassetteSpacing.m) {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonAlbumCard()
                            .frame(width: 150)
                    }
                }
            }
        }
    }

    private var skeletonMixShelf: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(String(localized: "Made for You", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteSectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CassetteSpacing.m) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: PersonalMixCard.cardWidth, height: PersonalMixCard.cardHeight)
                    }
                }
                .frame(height: PersonalMixCard.cardHeight)
            }
            .frame(height: PersonalMixCard.cardHeight)
        }
    }
}
