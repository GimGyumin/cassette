// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import MediaPlayer
import OSLog
#if os(iOS)
import UIKit
#endif

extension NowPlayingService {
    // MARK: - Lifecycle

    func start() async {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        originalArtworkObserver = NotificationCenter.default.addObserver(forName: OriginalArtwork.didInstall, object: nil, queue: nil) { [weak self] notification in
            guard let coverID = notification.object as? String else { return }
            Task { await self?.refreshDownloadedArtwork(coverID: coverID) }
        }

        #if os(iOS)
        if #available(iOS 27.0, *) {
            // Siri relevance is independent of the system playback session. MediaPlayer
            // alone owns metadata and commands; do not create a second MediaSession.
            nowPlayingEntityPublisher = await MainActor.run { CassetteNowPlayingEntityPublisher() }
        }
        #endif

        // Register every command handler SYNCHRONOUSLY, on the MAIN THREAD, in ONE atomic block — before any
        // actor suspension and before the first now-playing info is set. MPRemoteCommandCenter is a main-thread
        // API: registering it from the NowPlayingService actor (off-main) let iOS snapshot setSupportedCommands
        // mid-registration — capturing only {Play, Pause} and never re-snapshotting, so Next / Previous /
        // scrubber showed greyed out (partial/random by run = the registration-vs-snapshot race). One
        // main-thread block guarantees the supported set is COMPLETE at iOS's single snapshot. addTarget is what
        // makes a command "supported"; isEnabled (in updateRemoteCommandsAvailability) only greys/ungreys it.
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()

            center.playCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.play) }
                return .success
            }

            center.pauseCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.pause) }
                return .success
            }

            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.toggle) }
                return .success
            }

            center.nextTrackCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.next) }
                return .success
            }

            center.previousTrackCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.previous) }
                return .success
            }

            #if os(macOS)
            // macOS Control Center may route the previous-track gesture through skipBackwardCommand
            // instead of previousTrackCommand. Register both so the gesture works on either path.
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 0)]
            center.skipBackwardCommand.addTarget { [weak self] _ in
                Task { await self?.enqueueRemoteCommand(.previous) }
                return .success
            }
            #endif

            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                Task { await self?.enqueueRemoteCommand(.seek(seekEvent.positionTime)) }
                return .success
            }
        }

        #if os(iOS)
        // Retry deferred lock-screen artwork once the app returns to the foreground.
        installForegroundArtworkRetryObserver()
        #endif
    }

    /// Framework command cancellation must not cancel the accepted seek operation.
    /// Both native and legacy system controls use this service-owned, coalesced task.
    func seekFromSystem(to position: Double) async {
        enqueueRemoteCommand(.seek(position))
        let seek = remoteSeekTask
        await seek?.value
    }

    private func enqueueRemoteCommand(_ command: RemoteCommand) {
        let precedingCommand = remoteCommandTail
        let playerService = playerService
        remoteSeekTask?.cancel()
        remoteSeekTask = nil
        if case .seek(let position) = command {
            remoteSeekTask = Task {
                await precedingCommand?.value
                guard !Task.isCancelled else { return }
                await playerService.seek(to: position)
            }
            return
        }
        remoteCommandTail = Task {
            await precedingCommand?.value
            guard !Task.isCancelled else { return }
            switch command {
            case .play:
                await playerService.resume()
            case .pause:
                await playerService.pause()
            case .toggle:
                await playerService.togglePlayPause()
            case .next:
                do {
                    try await playerService.skipToNext()
                } catch {
                    Logger.nowPlaying.error("[PLAYBACK] skipToNext failed: \(error, privacy: .public)")
                }
            case .previous:
                do {
                    try await playerService.skipToPrevious()
                } catch {
                    Logger.nowPlaying.error("[PLAYBACK] skipToPrevious failed: \(error, privacy: .public)")
                }
            case .seek(let position):
                await playerService.seek(to: position)
            }
        }
    }

    // MARK: - Remote command availability

    func reassertRemoteCommands() async {
        let isLiveStream = currentSong?.isLiveStream ?? false
        // MPRemoteCommandCenter is main-thread; do not call actor-isolated helpers from MainActor.run.
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()
            center.nextTrackCommand.isEnabled = !isLiveStream
            center.previousTrackCommand.isEnabled = !isLiveStream
            #if os(macOS)
            center.skipBackwardCommand.isEnabled = !isLiveStream
            #endif
            center.changePlaybackPositionCommand.isEnabled = !isLiveStream
            // Nudge Now Playing center so iOS re-snapshots supported commands after sleep.
            if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        Logger.nowPlaying.debug("[RCC] reassertRemoteCommands isLiveStream=\(isLiveStream, privacy: .public)")
    }

    func updateRemoteCommandsAvailability(isLiveStream: Bool) async {
        await MainActor.run {
            let center = MPRemoteCommandCenter.shared()
            // Skip, previous, and scrubbing are meaningless for a live stream.
            // play/pause/togglePlayPause remain enabled in both modes (always-on).
            center.nextTrackCommand.isEnabled = !isLiveStream
            center.previousTrackCommand.isEnabled = !isLiveStream
            #if os(macOS)
            center.skipBackwardCommand.isEnabled = !isLiveStream
            #endif
            center.changePlaybackPositionCommand.isEnabled = !isLiveStream
        }
        Logger.nowPlaying.debug(
            "[REMOTE] updateRemoteCommandsAvailability — isLiveStream=\(isLiveStream, privacy: .public) nextEnabled=\(!isLiveStream, privacy: .public)"
        )
    }

    // MARK: - Discord RPC

    #if os(macOS)
    nonisolated func postDiscordRPC(_ event: DiscordRPCEvent) {
        guard UserDefaults.standard.bool(forKey: "cassette.discordRPC.enabled") else { return }

        let port = 47832
        let urlString: String
        var body: Data?

        switch event {
        case .nowPlaying(let info):
            urlString = "http://localhost:\(port)/now-playing"
            body = try? JSONEncoder().encode(info)
        case .stopped:
            urlString = "http://localhost:\(port)/playback-stopped"
        }

        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
    #endif

    private func appendToDebugLog(_ message: String) {
        // Forward to the off-actor, opt-in, size-capped logger — no synchronous disk I/O on the playback
        // actor or the track-change path (audit finding L4). Disabled by default; see RemoteCommandDebugLog.
        RemoteCommandDebugLog.log(message)
    }
}

/// Opt-in, size-capped, off-actor file logger for the MPRemoteCommandCenter skip/previous diagnostic.
///
/// This is the active diagnostic for the remote-command (next/previous) bug, so the capability is kept —
/// but made safe. It is OFF by default and enabled at runtime via the UserDefaults flag `debug.rccFileLog`
/// (so it can be turned on for a release build on a real device, unlike a `#if DEBUG` gate). When enabled it
/// appends on a background serial queue — never blocking the playback actor — and rotates the file at a size
/// cap so `cassette_debug.log` can never grow unbounded.
private enum RemoteCommandDebugLog {
    /// Runtime toggle, default OFF. Set this UserDefaults bool to true to capture the log while diagnosing.
    nonisolated static let enabledKey = "debug.rccFileLog"
    /// Rotate when the active log reaches this size; total on disk is bounded to ~2x this (.log + .log.1).
    private nonisolated static let maxBytes = 256 * 1024
    nonisolated static let queue = DispatchQueue(label: "fr.mathieu-dubart.cassette.rcc-debug-log", qos: .utility)

    nonisolated static func log(_ message: String) {
        #if os(iOS)
        // Cheap in-memory flag check on the caller; when disabled (the default) we do zero work and zero I/O.
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let line = "\(Date()): \(message)\n"
        queue.async {
            let fm = FileManager.default
            guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = line.data(using: .utf8) else { return }
            let file = docs.appendingPathComponent("cassette_debug.log")
            // Rotate before appending once at/over the cap so the file can't grow without bound.
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int, size >= maxBytes {
                let rotated = docs.appendingPathComponent("cassette_debug.log.1")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: file, to: rotated)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: file)
            }
        }
        #endif
    }
}

#if os(macOS)
nonisolated enum DiscordRPCEvent {
    case nowPlaying(DiscordNowPlayingInfo)
    case stopped
}

nonisolated struct DiscordNowPlayingInfo: Encodable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let startedAt: Double
}
#endif
