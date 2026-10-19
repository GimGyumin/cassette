// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

struct DiscoverView: View {
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @State private var vm: DiscoverViewModel?
    @State private var replaySummary: WrappedData?
    @State private var isLoadingReplaySummary = false
    @State private var radioStations: [InternetRadioStation] = []
    #if os(iOS)
    @Namespace private var freshReleaseZoomNamespace
    #else
    @State private var selectedRelease: AlbumRecommendation?
    #endif
    @State private var showAllFreshReleases = false
    @State private var allReleasesVM: AllFreshReleasesViewModel?
    @State private var isListenBrainzConnected: Bool = false
    /// Secondary shelves (fresh / spatial / radio / yearly) — once per session unless pull-to-refresh.
    @State private var didLoadSecondary = false
    @State private var isStartingShuffle = false
    @State private var loadedServerID: String?
    @State private var isHeaderScrolled = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if let feed = container?.homeDiscoveryFeed {
                    let artists = feed.stationArtists(from: feed.recentlyAdded)
                    if !artists.isEmpty { RecommendedStationsShelf(artists: artists) }
                }
                SmartShuffleBanner(albums: container?.homeDiscoveryFeed.recentlyAdded ?? [], isLoading: isStartingShuffle) {
                    Task { await triggerSmartShuffle() }
                }
                MoodPlaylistShelf()
                if let vm {
                    if vm.isErrorState {
                        errorBanner(vm: vm)
                    } else {
                        freshReleasesSection(vm: vm)
                        spatialAudioSection(vm: vm)
                    }
                    wrappedSection
                    internetRadioSection
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
        }
        .miniPlayerBottomMargin()
        .cassetteContentWidth(.fill)
        .navigationTitle(String(localized: "Discover", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .cassetteAccountProfileToolbar(isVisible: !isHeaderScrolled)
        .cassetteScrollingRootHeader(isScrolled: $isHeaderScrolled)
        .task(id: container?.serverState.activeServer?.id) {
            guard let container else { return }
            let serverId = container.serverState.activeServer?.id.uuidString
            if vm == nil || loadedServerID != serverId {
                vm = DiscoverViewModel(
                    libraryService: container.libraryService,
                    recommendationService: container.recommendationService,
                    serverId: serverId
                )
                loadedServerID = serverId
                didLoadSecondary = false
                radioStations = []
                replaySummary = nil
            }
            if allReleasesVM == nil {
                allReleasesVM = AllFreshReleasesViewModel(recommendationService: container.recommendationService)
            }
            // Discover is not the first tab — wait until Home's first list returns.
            await AppBootGate.waitForHome()
            await container.homeDiscoveryFeed.load()
            isListenBrainzConnected = await container.listenBrainzService.currentSnapshot().isEnabled
            guard !didLoadSecondary else { return }
            // Secondary sections after the main shelves are on screen.
            await vm?.loadFreshReleases()
            async let stations = container.radioService.listStations(forceRefresh: false)
            await vm?.loadSpatialAlbums()
            radioStations = (try? await stations) ?? []
            await loadReplaySummary()
            didLoadSecondary = true
        }
        .refreshable {
            await container?.homeDiscoveryFeed.load(forceRefresh: true)
            isListenBrainzConnected = await container?.listenBrainzService.currentSnapshot().isEnabled ?? false
            await vm?.loadFreshReleases()
            await vm?.loadSpatialAlbums(force: true)
            radioStations = (try? await container?.radioService.listStations(forceRefresh: true)) ?? []
            await loadReplaySummary()
            didLoadSecondary = true
        }
        #if os(iOS)
        .navigationDestination(for: AlbumRecommendation.self) { release in
            FreshReleaseDetailView(
                release: release,
                providers: container?.externalProvidersStore.load() ?? []
            )
            .cassetteZoomTransition(
                sourceID: release.id ?? "\(release.artistName)-\(release.title)",
                in: freshReleaseZoomNamespace
            )
        }
        #else
        .sheet(isPresented: Binding(
            get: { selectedRelease != nil },
            set: { if !$0 { selectedRelease = nil } }
        )) {
            if let release = selectedRelease {
                NavigationStack {
                    FreshReleaseDetailView(release: release, providers: container?.externalProvidersStore.load() ?? [])
                }
            }
        }
        #endif
        .navigationDestination(isPresented: $showAllFreshReleases) {
            if let vm = allReleasesVM {
                AllFreshReleasesView(vm: vm)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func freshReleasesSection(vm: DiscoverViewModel) -> some View {
        #if os(iOS)
        FreshReleasesCard(
            releases: vm.freshReleases,
            isLoading: vm.isLoadingFreshReleases,
            isListenBrainzConnected: isListenBrainzConnected,
            onSeeAll: { showAllFreshReleases = true },
            zoomNamespace: freshReleaseZoomNamespace
        )
        #else
        FreshReleasesCard(
            releases: vm.freshReleases,
            isLoading: vm.isLoadingFreshReleases,
            isListenBrainzConnected: isListenBrainzConnected,
            onSeeAll: { showAllFreshReleases = true },
            onTap: { release in selectedRelease = release }
        )
        #endif
    }

    @ViewBuilder
    private func spatialAudioSection(vm: DiscoverViewModel) -> some View {
        if vm.isLoadingSpatialAlbums && vm.spatialAlbums.isEmpty {
            section(title: String(localized: "Spatial Audio", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { skeletonScroll() }
        } else if !vm.spatialAlbums.isEmpty {
            AdaptiveAlbumShelf(
                title: String(localized: "Spatial Audio", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                albums: vm.spatialAlbums,
                showArtist: true
            )
        }
    }

    private func triggerSmartShuffle() async {
        guard let container, !isStartingShuffle else { return }
        isStartingShuffle = true
        defer { isStartingShuffle = false }
        do {
            try await container.playerService.playSmartShuffle()
        } catch {
            container.toastService.showError(smartShuffleErrorMessage(from: error))
        }
    }

    private func smartShuffleErrorMessage(from error: Error) -> String {
        if case CassetteError.smartShuffleEmpty = error {
            return "Smart Shuffle unavailable — try playing some tracks first or download more music for offline use."
        }
        return "Smart Shuffle failed. Please try again."
    }

    private var wrappedSection: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            HStack {
                Text(String(localized: "Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.cassetteSectionTitle)
                Spacer(minLength: 0)
                NavigationLink(value: HomeDestination.replay) {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "View Listening Stats", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            NavigationLink(value: HomeDestination.replay) {
                ReplaySummaryCard(
                    data: replaySummary,
                    isLoading: isLoadingReplaySummary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Open Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    private func loadReplaySummary() async {
        guard let container,
              let serverId = container.serverState.activeServer?.id.uuidString else {
            replaySummary = nil
            return
        }
        isLoadingReplaySummary = true
        defer { isLoadingReplaySummary = false }
        let period = WrappedPeriod.currentMonth()
        replaySummary = await container.statsService.wrappedData(
            for: period,
            serverId: serverId,
            calendar: .current
        )
    }

    private var internetRadioSection: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            HStack {
                Text("Internet Radio")
                    .font(.cassetteSectionTitle)
                Spacer(minLength: 0)
                NavigationLink {
                    RadioListView()
                } label: {
                    Text(String(localized: "See all", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.cassetteCaption)
                        .foregroundStyle(Color.cassetteAccent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if radioStations.isEmpty {
                NavigationLink {
                    RadioListView()
                } label: {
                    HStack(spacing: CassetteSpacing.s) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(Color.cassetteAccent)
                        Text("Browse Stations")
                            .font(.cassetteCellTitle)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(CassetteSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cassetteAccent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.standard, style: .continuous))
                }
                .buttonStyle(.plain)
                } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CassetteSpacing.s) {
                        ForEach(radioStations, id: \.id) { station in
                            RadioCard(station: station)
                        }
                    }
                        }
            }
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(title)
                .font(.cassetteSectionTitle)
                content()
        }
    }

    private func errorBanner(vm: DiscoverViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            HStack(spacing: CassetteSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow) // warning state — not brand accent
                Text("Unable to load Discover")
                    .font(.cassetteCellTitle)
            }
            if let message = vm.loadError?.localizedDescription {
                Text(message)
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Button {
                Task { await vm.load(forceRefresh: true, serverId: container?.serverState.activeServer?.id.uuidString) }
            } label: {
                Text("Retry")
                    .font(.cassetteCellTitle)
                    .foregroundStyle(.white)
                            .padding(.vertical, CassetteSpacing.s)
                    .cassetteAccentGlassCapsule()
            }
            .buttonStyle(.plain)
        }
        .padding(CassetteSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12)) // warning state — not brand accent
        .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.standard, style: .continuous))
        .padding(.horizontal, CassetteSpacing.m)
    }

    private func skeletonScroll() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: CassetteSpacing.s) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                        SkeletonBlock(width: 140, height: 140, cornerRadius: CassetteCornerRadius.standard)
                        SkeletonBlock(width: 110, height: 12)
                        SkeletonBlock(width: 80, height: 10)
                    }
                    .frame(width: 140)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func emptyStateMessage(_ text: String) -> some View {
        Text(text)
            .font(.cassetteCaption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CassetteSpacing.l)
    }
}
