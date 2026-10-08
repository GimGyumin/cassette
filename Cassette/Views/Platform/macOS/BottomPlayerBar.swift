// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import SwiftUI
import AVKit
import OSLog
import SwiftSonic

struct BottomPlayerBar: View {
    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isScrubbing = false
    @State private var localScrubPosition: Double = 0
    @State private var artworkIsHovered = false
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var isFavorite = false
    @State private var isDownloadedLocally = false
    @State private var isDownloadingTrack = false
    @AppStorage("cassette.lastVolume") private var localVolume: Double = 0.7
    @State private var showVolumeSlider = false
    @State private var sliderDismissTask: Task<Void, Never>?
    @State private var barWidth: CGFloat = 800

    var onArtworkTap: (() -> Void)? = nil
    var isLyricsPanelOpen: Bool = false
    var isFullPlayerPresented: Bool = false
    var onLyricsTap: (() -> Void)? = nil

    private var playerState: PlayerState? { container?.playerState }
    private var currentTrack: DisplayableSong? { playerState?.currentTrack }
    private var isPlaying: Bool { playerState?.playbackState == .playing }
    private var isLoading: Bool { playerState?.playbackState.isAwaitingAudio == true }
    private var isLiveStream: Bool { playerState?.isLiveStream == true }
    private var noTrack: Bool { currentTrack == nil }
    private var hasContent: Bool { currentTrack != nil || playerState?.currentRadio != nil }
    private var displayTitle: String {
        if let radio = playerState?.currentRadio { return radio.name }
        return currentTrack?.title ?? "No track playing"
    }
    private var displayCoverArtId: String? {
        if let radio = playerState?.currentRadio { return radio.coverArt ?? radio.id }
        return currentTrack?.coverArtId ?? currentTrack?.id
    }
    private var isCompact: Bool { barWidth < 560 }
    private var isNarrow: Bool { barWidth < 400 }
    /// Hide only AirPlay / volume expansion when very tight — lyrics + queue stay available.
    private var hidePeripheralControls: Bool { barWidth < 480 }
    private var serverId: UUID? { container?.serverState.activeServer?.id }

    /// Lossless / Hi-Res / Dolby badge for the mini bar (hidden when stream is lossy-transcoded or on expensive network).
    private var playbackQuality: AudioQualityKind? {
        guard let playerState, !playerState.isLiveStream, let track = currentTrack else { return nil }
        return AudioQualityClassifier.displayablePlaybackQuality(
            for: track,
            isExpensive: container?.serverState.isExpensive == true,
            isTranscoding: playerState.isDeliveringTranscodedAudio
        )
    }

    private var artistAlbumLine: String {
        guard !isLiveStream else { return " " }
        let parts = [currentTrack?.artist, currentTrack?.albumName].compactMap { $0 }
        return parts.isEmpty ? " " : parts.joined(separator: " — ")
    }

    var body: some View {
        HStack(spacing: 0) {
            playbackControls
                .padding(.horizontal, 16)

            centerBlock
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isNarrow ? 6 : 12)

            secondaryActions
                .padding(.horizontal, isNarrow ? 8 : 16)
        }
        .frame(height: 50)
        .background {
            if #available(macOS 26.0, *), !CassettePerformance.preferCheapChrome {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .onChange(of: isCompact) { _, compact in
            if compact && showVolumeSlider {
                animatePanel { showVolumeSlider = false }
                sliderDismissTask?.cancel()
                sliderDismissTask = nil
            }
        }
        .task(id: currentTrack?.id) {
            await refreshFavorite()
            await refreshDownloadState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteToggleQueue)) { _ in
            guard !isFullPlayerPresented else { return }
            showQueue.toggle()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = currentTrack {
                AddToPlaylistSheet(song: track)
                    .environment(artworkImageCache)
            }
        }
    }

    // MARK: - Center Block

    @ViewBuilder
    private var centerBlock: some View {
        VStack(spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                artworkThumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(!hasContent ? .secondary : .primary)
                    if isLiveStream {
                        liveIndicator
                    } else {
                        Text(artistAlbumLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let quality = playbackQuality {
                    MacMiniPlayerQualityBadge(quality: quality)
                }

                if !noTrack {
                    ellipsisMenu
                }
            }

            if !isLiveStream {
                thinScrubber
            }
        }
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artworkThumbnail: some View {
        Group {
            if hasContent {
                CoverArtView(id: displayCoverArtId ?? "", size: 32)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .scaleEffect(artworkIsHovered ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: artworkIsHovered)
        .onHover { hovering in
            artworkIsHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onArtworkTap?() }
    }

    // MARK: - Scrubber

    private var thinScrubber: some View {
        ProgressSlider(
            value: Binding(
                get: { isScrubbing ? localScrubPosition : (playerState?.position ?? 0) },
                set: { localScrubPosition = $0 }
            ),
            total: max(1, playerState?.duration ?? 1),
            onEditingChanged: { editing in
                if editing { localScrubPosition = playerState?.position ?? 0 }
                isScrubbing = editing
                if !editing {
                    let pos = localScrubPosition
                    Task { await container?.playerService.seek(to: pos) }
                }
            },
            trackColor: .primary.opacity(0.12),
            fillColor: .primary,
            height: 8,
            trackHeight: 2
        )
        .disabled(noTrack)
    }

    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 5, height: 5)
            Text("LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: - Ellipsis Menu

    private var ellipsisMenu: some View {
        Menu {
            Button {
                if let t = currentTrack { postNavigateToAlbum(track: t) }
            } label: {
                GoToDestinationMenuLabel(
                    title: String(localized: "Go to Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    subtitle: currentTrack?.albumName,
                    systemImage: "square.stack"
                )
            }
            .disabled(currentTrack?.albumId == nil)
            Button {
                if let t = currentTrack { postNavigateToArtist(track: t) }
            } label: {
                GoToDestinationMenuLabel(
                    title: String(localized: "Go to Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                    subtitle: currentTrack?.artist,
                    systemImage: "music.mic"
                )
            }
            .disabled(currentTrack?.artistId == nil)
            Divider()
            Button("Add to Playlist…") {
                showAddToPlaylist = true
            }
            .disabled(noTrack || container?.serverState.isOnline != true)
            Divider()
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await toggleFavorite() }
            }
            .disabled(noTrack || container?.serverState.isOnline != true)
            Divider()
            if isDownloadingTrack {
                Button {} label: {
                    Label(
                        String(localized: "Downloading…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(true)
            } else {
                Button {
                    Task { await toggleDownload() }
                } label: {
                    Label(
                        isDownloadedLocally
                            ? String(localized: "Remove Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                            : String(localized: "Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        systemImage: isDownloadedLocally ? "arrow.down.circle.fill" : "arrow.down.circle"
                    )
                }
                .disabled(noTrack || (!isDownloadedLocally && container?.serverState.isOnline != true))
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(noTrack)
        .accessibilityLabel(String(localized: "More options", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await container?.playerService.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(playerState?.isShuffled == true ? Color.cassetteAccent : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(noTrack || isNarrow)
            .opacity(isNarrow ? 0 : 1)
            .accessibilityLabel(String(localized: "Shuffle", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue(playerState?.isShuffled == true ? String(localized: "On", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                Task { try? await container?.playerService.skipToPrevious() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(!hasContent ? .quaternary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
            .accessibilityLabel(String(localized: "Skip to previous", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            playPauseButton

            Button {
                Task { try? await container?.playerService.skipToNext() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(!hasContent ? .quaternary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
            .accessibilityLabel(String(localized: "Skip to next", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                Task {
                    if let mode = playerState?.repeatMode {
                        await container?.playerService.setRepeatMode(mode.next)
                    }
                }
            } label: {
                Image(systemName: playerState?.repeatMode.systemImage ?? "repeat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(playerState?.repeatMode != .off ? Color.cassetteAccent : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(noTrack || isNarrow)
            .opacity(isNarrow ? 0 : 1)
            .accessibilityLabel(String(localized: "Repeat", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue(repeatModeAccessibilityValue)
        }
    }

    private var repeatModeAccessibilityValue: String {
        switch playerState?.repeatMode {
        case .one: String(localized: "One", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .all: String(localized: "All", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        default: String(localized: "Off", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if isLoading {
            // Same glyph as the live control, inert while the stream is still being acquired.
            Image(systemName: "play.fill")
                .font(.system(size: 18))
                .foregroundStyle(!hasContent ? .secondary : .primary)
                .frame(width: 26, height: 26)
        } else {
            Button {
                Task {
                    if isPlaying {
                        await container?.playerService.pause()
                    } else {
                        await container?.playerService.resume()
                    }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(!hasContent ? .secondary : .primary)
                    .frame(width: 26, height: 26)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
            .accessibilityLabel(isPlaying ? String(localized: "Pause", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Play", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    // MARK: - Volume Slider (Apple Music–style expandable pill)

    private var volumeSliderPanel: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { localVolume },
                    set: { newValue in
                        localVolume = newValue
                        Task { await container?.playerService.setVolume(Float(newValue)) }
                        scheduleSliderDismiss()
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(.primary.opacity(0.85))
            .frame(width: 88)
            .accessibilityLabel(String(localized: "Volume", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue("\(Int(localVolume * 100))%")

            Image(systemName: volumeIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 16, height: 16)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Rectangle())
                .onTapGesture {
                    sliderDismissTask?.cancel()
                    animatePanel { showVolumeSlider = false }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.08))
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }

    private var volumeIcon: String {
        if localVolume == 0 { return "speaker.slash.fill" }
        if localVolume < 0.33 { return "speaker.fill" }
        if localVolume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    // MARK: - Secondary Actions

    private var secondaryActions: some View {
        HStack(spacing: 10) {
            // Icons collapse into an Apple Music–style volume capsule when the speaker is pressed.
            ZStack(alignment: .trailing) {
                secondaryIconsGroup
                    .opacity(showVolumeSlider ? 0 : 1)
                    .allowsHitTesting(!showVolumeSlider)

                if showVolumeSlider {
                    volumeSliderPanel
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.2), value: showVolumeSlider)

            if !showVolumeSlider, !hidePeripheralControls {
                Button {
                    animatePanel { showVolumeSlider = true }
                    scheduleSliderDismiss()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Volume", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .accessibilityValue("\(Int(localVolume * 100))%")
                .transition(.opacity)
            }
        }
    }

    private var secondaryIconsGroup: some View {
        HStack(spacing: isNarrow ? 8 : 12) {
            Button {
                onLyricsTap?()
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(isLyricsPanelOpen ? Color.cassetteAccent : .primary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .disabled(noTrack)
            .accessibilityLabel(String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue(isLyricsPanelOpen ? String(localized: "Open", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) : String(localized: "Closed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))

            Button {
                showQueue.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 12))
                    .foregroundStyle(showQueue ? Color.cassetteAccent : .primary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Queue", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .popover(isPresented: $showQueue, arrowEdge: .top) {
                QueueView()
                    .frame(width: 400, height: 600)
            }

            if !hidePeripheralControls {
                AirPlayButton()
                    .frame(width: 20, height: 20)
                    .accessibilityLabel(String(localized: "Audio output", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
    }

    // MARK: - Helpers

    private func refreshFavorite() async {
        guard let track = currentTrack, let container else {
            isFavorite = false
            return
        }
        isFavorite = container.favoritesService.isFavorite(itemType: .song, itemId: track.id)
    }

    private func refreshDownloadState() async {
        guard let track = currentTrack, let container, let sid = serverId else {
            isDownloadedLocally = false
            isDownloadingTrack = false
            return
        }
        isDownloadedLocally = await container.downloadService.isDownloaded(songId: track.id, serverId: sid)
        isDownloadingTrack = await container.downloadService.isDownloading(songId: track.id, serverId: sid)
    }

    private func toggleFavorite() async {
        guard let track = currentTrack, let container else { return }
        do {
            if isFavorite {
                try await container.favoritesService.unstar(itemType: .song, itemId: track.id)
            } else {
                try await container.favoritesService.star(itemType: .song, itemId: track.id)
            }
            isFavorite.toggle()
        } catch {
            Logger.ui.error("BottomPlayerBar: toggleFavorite failed — \(error)")
        }
    }

    private func toggleDownload() async {
        guard let track = currentTrack, let container, let sid = serverId else { return }
        do {
            if isDownloadedLocally {
                try await container.downloadService.remove(songId: track.id, serverId: sid)
                isDownloadedLocally = false
            } else {
                isDownloadingTrack = true
                defer { isDownloadingTrack = false }
                try await container.downloadService.download(song: track.asSong(), serverId: sid)
                isDownloadedLocally = true
                container.toastService.showConfirmation("Downloaded \(track.title)", coverArtId: track.coverArtId)
            }
        } catch {
            Logger.ui.error("BottomPlayerBar: toggleDownload failed — \(error)")
            container.toastService.showError(error.localizedDescription)
        }
    }

    private func scheduleSliderDismiss() {
        sliderDismissTask?.cancel()
        sliderDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            animatePanel {
                showVolumeSlider = false
            }
        }
    }

    private func animatePanel(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.2), changes)
        }
    }
}

struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(NSColor.controlAccentColor, for: .active)
        picker.setRoutePickerButtonColor(NSColor.secondaryLabelColor, for: .normal)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.setRoutePickerButtonColor(NSColor.controlAccentColor, for: .active)
        nsView.setRoutePickerButtonColor(NSColor.secondaryLabelColor, for: .normal)
    }
}
#endif
