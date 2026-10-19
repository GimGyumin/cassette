import SwiftUI
import SwiftSonic

struct HomeShelfHeading: View {
    let title: String
    var showsChevron = false
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.title2.bold()).foregroundStyle(.primary)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct HomePlaylistShelf: View {
    let playlists: [Playlist]
    let mixes: [PersonalMix]
    @Environment(\.appContainer) private var container
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: HomeDestination.libraryPlaylists) {
                HomeShelfHeading(title: String(localized: "Your Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), showsChevron: true)
            }.buttonStyle(.plain)
            if playlists.isEmpty && mixes.isEmpty {
                Text("Your playlists and personalized mixes appear here.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: HomeDestination.playlist(playlist)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    PlaylistCoverThumbnail(playlistId: playlist.id,
                                        serverId: container?.serverState.activeServer?.id,
                                        coverArtId: playlist.coverArt ?? playlist.id,
                                        title: playlist.name, size: PersonalMixCard.cardWidth)
                                    Text(playlist.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let date = playlist.changed {
                                            Text(String(localized: "Updated \(date.formatted(.relative(presentation: .named)))", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                        }
                                        Text(CassetteCountLabel.tracks(playlist.songCount))
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.frame(width: PersonalMixCard.cardWidth, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        ForEach(mixes) { mix in
                            NavigationLink(value: HomeDestination.personalMix(mix.kind)) { PersonalMixCard(mix: mix) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct RecommendedStationsShelf: View {
    let artists: [ArtistID3]
    @Environment(\.appContainer) private var container
    @State private var startingArtistID: String?
    @State private var stationTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeShelfHeading(title: String(localized: "Stations for You", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                        Button {
                            startStation(artist)
                        } label: {
                            RecommendedStationCard(artist: artist, index: index)
                                .overlay(alignment: .topTrailing) {
                                    if startingArtistID == artist.id {
                                        ProgressView().padding(12).background(.regularMaterial, in: Circle()).padding(8)
                                    }
                                }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onDisappear { stationTask?.cancel(); startingArtistID = nil }
    }

    private func startStation(_ artist: ArtistID3) {
        guard let container, startingArtistID != artist.id else { return }
        stationTask?.cancel()
        startingArtistID = artist.id
        stationTask = Task { @MainActor in
            defer { if !Task.isCancelled, startingArtistID == artist.id { startingArtistID = nil } }
            guard let snapshot = await GeneratedPlaylistSource.artistStation(artist)
                .snapshot(in: container, forceRefresh: false), !Task.isCancelled else { return }
            guard !snapshot.tracks.isEmpty else {
                container.toastService.showError("No songs available for this station.")
                return
            }
            do { try await container.playerService.play(tracks: snapshot.tracks.shuffled(), startIndex: 0) }
            catch {
                if !Task.isCancelled { container.toastService.showError(error.localizedDescription) }
            }
        }
    }
}

struct RecommendedStationCard: View {
    let artist: ArtistID3
    let index: Int
    var body: some View {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(colors: index.isMultiple(of: 2)
                                        ? [Color(hex: "#17465B"), Color(hex: "#2698AB")]
                                        : [Color(hex: "#482B60"), Color(hex: "#B94968")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                    CoverArtView(id: artist.coverArt ?? artist.id, size: 280, placeholderSystemImage: "person.fill")
                                        .frame(width: 116, height: 116).clipShape(Circle())
                                }
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(GeneratedPlaylistSource.artistStation(artist).title)
                                    .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text("Radio Station").font(.subheadline).foregroundStyle(.secondary)
                            }.frame(width: 160, alignment: .leading)
    }
}

struct MoodPlaylistShelf: View {
    private let kinds: [PersonalMixKind] = [.focus, .chill, .getUp]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeShelfHeading(title: String(localized: "Moods", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(kinds, id: \.self) { kind in
                        NavigationLink(value: HomeDestination.personalMix(kind)) {
                            MoodPlaylistCard(kind: kind)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct MoodPlaylistCard: View {
    let kind: PersonalMixKind
    var body: some View {
                            VStack(alignment: .leading, spacing: 8) {
                                PersonalMixArtwork(kind: kind, showsTitle: false, showsSymbol: true)
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(String(localized: String.LocalizationValue(kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            }.frame(width: 140, alignment: .leading)
    }
}

struct SmartShuffleBanner: View {
    let albums: [AlbumID3]
    var isLoading = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 4) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Smart Shuffle", systemImage: "shuffle").font(.headline)
                    Text("Rediscover Your Library").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("A new mix, every time").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 8) {
                        if isLoading { ProgressView().tint(.white) }
                        else { Image(systemName: "play.fill") }
                        Text("Shuffle").font(.headline)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white.opacity(0.18), in: Capsule())
                }.frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    ForEach(Array(albums.prefix(3).enumerated()), id: \.element.id) { index, album in
                        CoverArtView(id: album.coverArt ?? album.id, size: 240)
                            .frame(width: 82, height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .rotationEffect(.degrees(Double(index - 1) * 12))
                            .offset(x: CGFloat(index - 1) * 6, y: CGFloat(index - 1) * 30)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                    }
                }.frame(width: 100, height: 150)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 202, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: "#8A163B"), Color(hex: "#DC3016")], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
