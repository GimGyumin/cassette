// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

// Architecture note — navigation regression guard:
// iOS uses NavigationLink(value:) + .navigationDestination(for: AlbumRecommendation.self)
// registered on this view. Do NOT switch to .navigationDestination(item:) or .sheet(item:) —
// state-driven item presentation produces duplicate-push bugs inside a pushed NavigationStack
// context. Do NOT pass a SwiftData @Model as the NavigationLink value; AlbumRecommendation
// is a plain struct and must remain so.

import SwiftUI

struct AllFreshReleasesView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let vm: AllFreshReleasesViewModel

    #if os(iOS)
    @Namespace private var releaseZoomNamespace
    #else
    @State private var selectedRelease: AlbumRecommendation?
    #endif

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private var usesGrid: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 130), spacing: CassetteSpacing.m)]
    }

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.groupedReleases.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Releases", systemImage: "sparkles")
                } description: {
                    Text("Nothing in the past 3 months from artists you listen to.")
                }
            } else {
                scrollContent
            }
        }
        .navigationTitle(String(localized: "Fresh Releases", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AlbumRecommendation.self) { release in
            FreshReleaseDetailView(
                release: release,
                providers: container?.externalProvidersStore.load() ?? []
            )
            .cassetteZoomTransition(
                sourceID: release.id ?? "\(release.artistName)-\(release.title)",
                in: releaseZoomNamespace
            )
        }
        #else
        .sheet(isPresented: Binding(
            get: { selectedRelease != nil },
            set: { if !$0 { selectedRelease = nil } }
        )) {
            if let release = selectedRelease {
                NavigationStack {
                    FreshReleaseDetailView(
                        release: release,
                        providers: container?.externalProvidersStore.load() ?? []
                    )
                }
            }
        }
        #endif
        .task { await vm.loadReleases() }
    }

    // MARK: - Scroll content

    @ViewBuilder
    private var scrollContent: some View {
        if usesGrid {
            releasesGrid
        } else {
            #if os(iOS)
            releasesList
            #else
            releasesGrid
            #endif
        }
    }

    #if os(iOS)
    private var releasesList: some View {
        List {
            ForEach(vm.groupedReleases, id: \.month) { section in
                Section(Self.monthFormatter.string(from: section.month)) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, release in
                        NavigationLink(value: release) {
                            FreshReleaseRow(
                                release: release,
                                zoomSourceId: release.id ?? "\(release.artistName)-\(release.title)",
                                zoomNamespace: releaseZoomNamespace
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await vm.loadReleases() }
        .miniPlayerBottomMargin()
    }
    #endif

    @ViewBuilder
    private var releasesGrid: some View {
        let sv = ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(vm.groupedReleases, id: \.month) { section in
                    Section {
                        LazyVGrid(columns: gridColumns, spacing: CassetteSpacing.m) {
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, release in
                                #if os(iOS)
                                FreshReleaseAlbumCell(
                                    release: release,
                                    zoomSourceId: release.id ?? "\(release.artistName)-\(release.title)",
                                    zoomNamespace: releaseZoomNamespace
                                )
                                #else
                                FreshReleaseAlbumCell(release: release, onTap: { selectedRelease = release })
                                #endif
                            }
                        }
                        .padding(.horizontal, CassetteSpacing.m)
                        .padding(.bottom, CassetteSpacing.l)
                    } header: {
                        Text(Self.monthFormatter.string(from: section.month))
                            .font(.title3.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, CassetteSpacing.m)
                            .padding(.vertical, CassetteSpacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                    }
                }
            }
        }
        .refreshable { await vm.loadReleases() }
        .miniPlayerBottomMargin()

        #if os(macOS)
        if #available(macOS 26.0, *) {
            sv
                .ignoresSafeArea(.container, edges: .top)
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            sv.ignoresSafeArea(.container, edges: .top)
        }
        #else
        sv
        #endif
    }

    // MARK: - iOS row

    #if os(iOS)
    private struct FreshReleaseRow: View {
        let release: AlbumRecommendation
        var zoomSourceId: String? = nil
        var zoomNamespace: Namespace.ID? = nil

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f
        }()

        var body: some View {
            HStack(spacing: CassetteSpacing.m) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ExternalCoverView(url: release.coverArtURL) {
                            Color.secondary.opacity(0.2)
                        }
                    }
                    .cassetteCoverStyle()
                    .frame(width: 52, height: 52)
                    .cassetteMatchedTransitionSource(id: zoomSourceId, in: zoomNamespace)

                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title)
                        .font(.cassetteCellTitle)
                        .lineLimit(1)
                    Text(release.artistName)
                        .font(.cassetteCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let date = release.releaseDate {
                        Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                            .font(.cassetteCaption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
    #endif
}
