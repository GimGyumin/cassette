// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import AudioStreaming
import SwiftSonic
import OSLog
import AVFoundation

#if os(iOS)
import AVFAudio
import UIKit
#endif

// Actor-isolated implementation; PlayerService remains the single playback owner.
extension PlayerService {
    // MARK: - Live Stream

    func playRadio(_ station: InternetRadioStation) async throws {
        guard await permitsNewTransportCommand(), stopBarrierCount == 0 else { return }
        clearInterruptionForExplicitPlayback()
        transportCommandID &+= 1
        transport.intent = .play
        transport.terminalContext = nil
        let resetContext = playbackContext
        await audioObjectsResetTask?.value
        guard contextIsCurrent(resetContext) else { return }
        isRestoringSession = false
        pendingRestoreInfo = nil
        playbackRequestTask?.cancel()
        playbackEpoch &+= 1
        let context = playbackContext
        let publication = makePlaybackPublication()
        cancelGaplessBridge()
        cancelPendingScrobble()
        cancelPendingCacheDownload()
        cancelFadeTasks()
        let source = try await mediaResolver.resolveRadio(station)
        guard contextIsCurrent(context), transport.permitsAudio else { return }

        #if os(iOS)
        let codecResult = await checkCodecSupport(url: source.url, headers: source.customHeaders)
        if case .unsupported(let contentType) = codecResult {
            Logger.player.warning("[RADIO-CODEC] rejected stream, content-type=\(contentType, privacy: .public)")
            await MainActor.run {
                toastService.show(
                    "This radio uses an unsupported audio format. Cassette can play MP3 and AAC live streams currently.",
                    style: .error,
                    duration: 5.0
                )
            }
            return
        }
        #endif

        guard contextIsCurrent(context), transport.permitsAudio else { return }
        await applyReplayGain(track: nil, config: ReplayGainConfig(enabled: false, mode: .track, preAmp: 0, preventClipping: true), context: context)
        guard contextIsCurrent(context), transport.permitsAudio else { return }
        isTrackTransitionPending = false
        stopProgressTimer()
        cancelAutoExtendFetch()
        liveStreamStallTask?.cancel()
        liveStreamStallTask = nil
        currentSource = source
        pendingRestoreInfo = nil

        restorePauseTask?.cancel()
        restorePauseTask = nil
        if isMutedForRestore {
            setEngineVolume(restoredVolume)
            isMutedForRestore = false
        }

        #if os(iOS)
        configureAudioSessionIfNeeded(preferMultichannel: false)
        #endif

        guard await commitPresentation(context, { state in
            state.currentTrack = nil
            state.currentPlaybackTrack = nil
            state.currentRadio = station
            state.isSmartShuffleActive = false
            state.originalQueueEndIndex = nil
            state.playbackState = .loading
            state.position = 0
            state.pendingSeekPosition = nil
            state.duration = 0
            state.isSeekable = false
            state.isDeliveringTranscodedAudio = false
            return true
        }) else { return }

        guard contextIsCurrent(context), transport.permitsAudio else { return }
        #if os(macOS)
        startEnginePlayback(url: source.url, headers: source.customHeaders, useSystemPlayer: true)
        #else
        startEnginePlayback(url: source.url, headers: source.customHeaders, useSystemPlayer: false)
        #endif

        // The published state stays `.loading` until an engine confirms the stream is really
        // producing audio (AVPlayer's time-control status on macOS, AudioStreaming's state
        // callback on iOS). Publishing `.playing` here showed the transport's pause/stop control
        // while the station was still connecting — the stream is not stoppable-in-progress, it has
        // not started at all. The stall monitor below needs no state change: it fails a station
        // over after 8 seconds without progress either way.
        await MainActor.run {
            state.isPlaybackAvailable = true
        }

        startProgressTimer()
        startLiveStreamStallMonitor(stationName: station.name)

        let artworkHeaders: [String: String]
        do {
            artworkHeaders = try await serverService.activeCredentials().customHeaders
        } catch {
            Logger.player.warning("[CREDENTIALS] activeCredentials failed, using empty headers: \(error, privacy: .public)")
            artworkHeaders = [:]
        }
        guard contextIsCurrent(context) else { return }
        await nowPlayingService?.update(with: NowPlayingSnapshot(
            title: station.name,
            artist: "Live Radio",
            album: nil,
            duration: 0,
            position: 0,
            playbackRate: 1.0,
            artworkURL: nil,
            artworkHeaders: artworkHeaders,
            coverArtId: station.coverArt,
            isLiveStream: true,
            radioStationName: station.name,
            isrc: nil,
            publication: publication
        ))

        guard contextIsCurrent(context) else { return }
        startPositionSaveTimer()
        Logger.player.info("Started live stream radio '\(station.name, privacy: .public)'")
    }

    // MARK: - Live Stream Codec Check & Failsafe

    private nonisolated enum LiveStreamCodecResult {
        case supported
        case unsupported(contentType: String)
        case ambiguous
    }

    private func checkCodecSupport(url: URL, headers: [String: String]) async -> LiveStreamCodecResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 2.0)
        request.httpMethod = "HEAD"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            Logger.player.debug("[RADIO-CODEC] HEAD request failed or timed out — letting player try")
            return .ambiguous
        }
        let rawType = (httpResponse.allHeaderFields["Content-Type"] as? String ?? "").lowercased()
        let contentType = rawType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""

        let whitelist: Set<String> = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/x-aac", "audio/aacp"]
        let blacklist: Set<String> = ["audio/flac", "audio/x-flac", "audio/opus", "audio/ogg", "audio/vorbis"]

        if whitelist.contains(contentType) {
            Logger.player.debug("[RADIO-CODEC] content-type=\(contentType, privacy: .public) → supported")
            return .supported
        }
        if blacklist.contains(contentType) {
            return .unsupported(contentType: contentType)
        }
        Logger.player.debug("[RADIO-CODEC] content-type=\(contentType.isEmpty ? "(empty)" : contentType, privacy: .public) → ambiguous, letting player try")
        return .ambiguous
    }

    private func startLiveStreamStallMonitor(stationName: String) {
        let context = playbackContext
        liveStreamStallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let (isStillLive, position) = await MainActor.run { (self.state.isLiveStream, self.state.position) }
            guard isStillLive, position < 1.0 else { return }
            await self.handleLiveStreamFailure(stationName: stationName, error: nil, expectedContext: context)
        }
    }

    func handleLiveStreamFailure(stationName: String, error: Error?, expectedContext: PlaybackContext? = nil) async {
        let context = expectedContext ?? playbackContext
        let isStillLive = await MainActor.run { state.isLiveStream }
        guard isStillLive, contextIsCurrent(context), transport.terminalContext != context else { return }

        Logger.player.error("[RADIO-FAILSAFE] live stream '\(stationName, privacy: .public)' failed: \(error?.localizedDescription ?? "stall timeout", privacy: .public)")

        await finishPlaybackFailure(error.map { .playbackFailed(.classify($0)) } ?? .timeout, context: context)
        await commitPresentation(context) { state in
            state.currentRadio = nil
            state.playbackState = .idle
            toastService.show(
                "Stream unavailable. The radio may be down or use an unsupported format.",
                style: .error,
                duration: 5.0
            )
            return true
        }
    }
}
