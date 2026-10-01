// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic
import OSLog

struct WrappedView: View {
    @Environment(\.appContainer) private var container
    @State private var selectedPeriod: WrappedPeriod = .currentMonth()
    @State private var data: WrappedData?
    @State private var isLoading = true
    @State private var wrappedPlaylistId: String?
    @State private var appeared = false
    @State private var loadFailed = false
    @State private var refreshDebounceTask: Task<Void, Never>?
    #if DEBUG
    @AppStorage("debug.wrappedFakeDataActive") private var overrideWithFakeData = false
    @AppStorage("debug.wrappedFakeDataJSON") private var persistedFakeDataJSON = ""
    #endif

    init(initialPeriod: WrappedPeriod = .currentMonth()) {
        _selectedPeriod = State(initialValue: initialPeriod)
    }

    private var availablePeriods: [WrappedPeriod] {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        var periods: [WrappedPeriod] = (1...month).map { .month(year: year, month: $0) }
        periods.append(.year(year))
        return periods
    }

    private var currentYear: Int {
        switch selectedPeriod {
        case .month(let year, _): return year
        case .year(let year): return year
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CassetteSpacing.xl) {
                WrappedPeriodPicker(selectedPeriod: $selectedPeriod, availablePeriods: availablePeriods)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, CassetteSpacing.xxxxl)
                } else if loadFailed {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Unable to Load Recap",
                        subtitle: "Something went wrong. Pull to refresh.",
                        action: .init(label: "Retry") { Task { await loadData() } }
                    )
                } else if let d = data, d.totalTracksPlayed > 0 {
                    WrappedStatHero(data: d)
                        .cascadeAppear(order: 0, trigger: appeared)
                    WrappedTopArtistsSection(artists: d.topArtists)
                        .cascadeAppear(order: 1, trigger: appeared)
                    WrappedTopTracksSection(tracks: d.topTracks)
                        .cascadeAppear(order: 2, trigger: appeared)
                    WrappedTopAlbumsSection(albums: d.topAlbums)
                        .cascadeAppear(order: 3, trigger: appeared)
                    WrappedAwardsSection(data: d)
                        .cascadeAppear(order: 4, trigger: appeared)
                    if case .year = selectedPeriod {
                        WrappedYearCard(
                            year: currentYear,
                            firstTrack: d.firstTrackOfPeriod,
                            lastTrack: d.lastTrackOfPeriod,
                            playlistId: wrappedPlaylistId
                        )
                        .cascadeAppear(order: 5, trigger: appeared)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.l)
            .padding(.bottom, CassetteSpacing.xl)
        }
        .refreshable { await loadData() }
        .miniPlayerBottomMargin()
        .navigationTitle(String(localized: "Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        .task(id: selectedPeriod) {
            await loadData()
        }
        .background {
            if let container,
               let serverId = container.serverState.activeServer?.id.uuidString {
                PlaybackEventWatcher(serverId: serverId) {
                    scheduleQuietRefresh()
                }
                .modelContainer(container.listeningModelContainer)
            }
        }
        .onDisappear {
            refreshDebounceTask?.cancel()
            refreshDebounceTask = nil
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: CassetteSpacing.s) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(Color.cassetteAccent.opacity(0.5))
            Text(String(localized: "No listens for this period.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteCellTitle)
            Text(String(localized: "Listen up — Replay will keep track of your activity.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, CassetteSpacing.xxxxl)
    }

    // MARK: - Data loading

    /// Debounce live playback inserts so each scrobble doesn't rebuild the whole Recap UI.
    private func scheduleQuietRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await refreshData()
        }
    }

    private func refreshData() async {
        #if DEBUG
        guard !overrideWithFakeData else { return }
        #endif
        guard let container, let serverId = container.serverState.activeServer?.id.uuidString else { return }
        let result = await container.statsService.wrappedData(for: selectedPeriod, serverId: serverId, calendar: .current)
        guard !Task.isCancelled else { return }
        data = result
    }

    private func loadData() async {
        #if DEBUG
        if overrideWithFakeData {
            guard isLoading,
                  !persistedFakeDataJSON.isEmpty,
                  let jsonData = persistedFakeDataJSON.data(using: .utf8),
                  let restored = try? JSONDecoder().decode(WrappedData.self, from: jsonData) else { return }
            selectedPeriod = restored.period
            data = restored
            isLoading = false
            loadFailed = false
            if case .year = restored.period { wrappedPlaylistId = "debug-playlist" }
            appeared = true
            return
        }
        #endif
        loadFailed = false
        guard let container, let serverId = container.serverState.activeServer?.id.uuidString else {
            isLoading = false
            loadFailed = true
            return
        }
        Logger.wrapped.debug("[WRAPPED-VIEW] fetch start period=\(selectedPeriod.displayName, privacy: .public)")
        let isFirstPaint = data == nil
        appeared = false
        if isFirstPaint { isLoading = true }
        wrappedPlaylistId = nil
        let result = await container.statsService.wrappedData(
            for: selectedPeriod, serverId: serverId, calendar: .current
        )
        guard !Task.isCancelled else { return }
        if case .year(let y) = selectedPeriod {
            wrappedPlaylistId = await container.wrappedPlaylistService.playlistId(year: y, serverId: serverId)
        }
        data = result
        isLoading = false
        appeared = true
        Logger.wrapped.debug("[WRAPPED-VIEW] fetch done totalPlays=\(result.totalTracksPlayed, privacy: .public)")
    }
}

// MARK: - Cascade appear modifier

private extension View {
    func cascadeAppear(order: Int, trigger: Bool) -> some View {
        modifier(CascadeAppearModifier(order: order, trigger: trigger))
    }
}

private struct CascadeAppearModifier: ViewModifier {
    let order: Int
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(trigger ? 1 : 0)
            .offset(y: (reduceMotion || trigger) ? 0 : 16)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.45, dampingFraction: 0.82).delay(Double(order) * 0.07),
                value: trigger
            )
    }
}

// MARK: - Server-scoped playback event watcher

private struct PlaybackEventWatcher: View {
    let onCountChange: () -> Void
    @Query private var events: [PlaybackEvent]

    init(serverId: String, onCountChange: @escaping () -> Void) {
        self.onCountChange = onCountChange
        let sid = serverId
        _events = Query(filter: #Predicate<PlaybackEvent> { $0.serverId == sid })
    }

    var body: some View {
        Color.clear
            .onChange(of: events.count) { _, _ in onCountChange() }
    }
}
