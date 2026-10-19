// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import SwiftSonic

/// Docked lyrics column beside main content (Apple Music–style), toggled from the mini player.
struct MacLyricsSidePanel: View {
    @Environment(\.appContainer) private var container

    @Environment(ArtworkImageCache.self) private var artworkCache
    @AppStorage("cassette.visuals.animatedArtwork") private var animatedArtwork = true
    @State private var artworkImage: PlatformImage?

    @State private var lyricsViewModel: LyricsViewModel?

    private var playerState: PlayerState? { container?.playerState }
    private var currentTrack: DisplayableSong? { playerState?.currentTrack }

    private var shouldShowLyricsTranslate: Bool {
        guard LyricsTranslationSettings.shared.isTranslationEnabled,
              let lyricsVM = lyricsViewModel,
              case .loaded = lyricsVM.state else { return false }
        return lyricsVM.needsTranslation
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let lyricsVM = lyricsViewModel {
                    LyricsView(viewModel: lyricsVM, lineAlignment: .center)
                } else if currentTrack == nil {
                    ContentUnavailableView(
                        "No Track Playing",
                        systemImage: "music.note",
                        description: Text("Play a song to see lyrics.")
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                if shouldShowLyricsTranslate, let lyricsVM = lyricsViewModel {
                    CassetteLyricsTranslateButton(
                        lyricsViewModel: lyricsVM,
                        contentColor: .secondary,
                        buttonSize: 28,
                        iconSize: 12
                    )
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
        .frame(width: 360, alignment: .center)
        .frame(maxHeight: .infinity)
        .background {
            AppleMusicLyricsBackground(
                coverImage: artworkImage, fallbackColor: .black,
                isPlaying: playerState?.playbackState == .playing,
                animated: animatedArtwork
            )
        }
        .clipped()
        .task(id: container?.playbackCoverId(for: currentTrack) ?? currentTrack?.effectiveCoverArtId) {
            let coverID = container?.playbackCoverId(for: currentTrack) ?? currentTrack?.effectiveCoverArtId
            let image = await artworkCache.load(coverArtId: coverID, tier: .hero)
            guard !Task.isCancelled else { return }
            artworkImage = image
        }
        .environment(\.colorScheme, .dark)
        .task(id: currentTrack?.id) {
            guard let track = currentTrack,
                  let serverId = container?.serverState.activeServer?.id,
                  let lyricsService = container?.lyricsService,
                  let pService = container?.playerService,
                  let pState = playerState else {
                lyricsViewModel = nil
                return
            }
            let newVM = LyricsViewModel(
                songId: track.id,
                serverId: serverId,
                lyricsService: lyricsService,
                playerService: pService,
                playerState: pState
            )
            lyricsViewModel = newVM
            await newVM.load()
        }
    }
}
#endif
