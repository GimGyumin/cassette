// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation
import OSLog

/// Adopts the `.audio.playAudio` schema. Resolves the requested song / album /
/// artist / playlist to a track list and hands it to the existing
/// `PlayerService` — no Siri-specific playback engine.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct CassettePlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audio"

    // MARK: Schema parameters

    var audioEntity: CassetteAudioItem
    @Parameter(default: [])
    var playbackAttributes: Set<CassettePlaybackAttributes>
    var queueLocation: CassetteQueueInsertionLocation?
    var warmupAudioQueueResult: CassetteWarmupAudioQueueResult?

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult {
        let tracks: [DisplayableSong]
        if warmupAudioQueueResult != nil,
           let id = audioEntity.entityID,
           let warmedTracks = SiriPlaybackWarmupStore.consume(for: id) {
            tracks = warmedTracks
        } else {
            // A mismatched/expired warmup must never leak into this request.
            SiriPlaybackWarmupStore.clear()
            tracks = try await resolveTracks()
        }
        Logger.player.info(
            "[SIRI-PLAY] entity=\(entityKind, privacy: .public) id=\(audioEntity.entityID?.rawValue ?? "nil", privacy: .public) resolvedTracks=\(tracks.count, privacy: .public) queueLocation=\(String(describing: queueLocation), privacy: .public)"
        )
        guard !tracks.isEmpty else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.noAudioEntity)
        }
        guard let player = await SiriBridge.playbackProvider?() else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.playerUnavailable)
        }

        do {
            switch queueLocation {
            case .none:
                Logger.player.info("[SIRI-PLAY] play(tracks:\(tracks.count, privacy: .public), startIndex:0)")
                try await player.play(tracks: tracks, startIndex: 0)
            case .next:
                await player.playNext(tracks)
            case .tail:
                await player.addToQueue(tracks)
            }

            if playbackAttributes.contains(.shuffle) {
                await player.toggleShuffle()
            }
            if playbackAttributes.contains(.repeat) {
                await player.setRepeatMode(.all)
            }
        } catch {
            SiriPlaybackWarmupStore.clear()
            throw AppIntentError(wrapping: CassetteAudioIntentError.playbackFailed(underlying: error))
        }

        return .result()
    }

    // MARK: Resolution

    private var entityKind: String {
        switch audioEntity {
        case .song: return "song"
        case .album: return "album"
        case .artist: return "artist"
        case .playlist: return "playlist"
        }
    }

    @MainActor
    private func resolveTracks() async throws -> [DisplayableSong] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        guard let id = audioEntity.entityID else { return [] }
        switch audioEntity {
        case .song:
            if let track = await catalog.playableSong(id: id) {
                Logger.player.info("[SIRI-PLAY] resolved song id=\(id.localId, privacy: .public) title=\(track.title, privacy: .public)")
                return [track]
            }
            Logger.player.warning("[SIRI-PLAY] song resolution returned nil id=\(id.localId, privacy: .public)")
            return []
        case .album:
            let tracks = await catalog.playableSongs(inAlbum: id)
            Logger.player.info("[SIRI-PLAY] resolved album id=\(id.localId, privacy: .public) tracks=\(tracks.count, privacy: .public)")
            return tracks
        case .artist:
            let tracks = await catalog.playableSongs(byArtist: id)
            Logger.player.info("[SIRI-PLAY] resolved artist id=\(id.localId, privacy: .public) tracks=\(tracks.count, privacy: .public)")
            return tracks
        case .playlist:
            let tracks = await catalog.playableSongs(inPlaylist: id)
            Logger.player.info("[SIRI-PLAY] resolved playlist id=\(id.localId, privacy: .public) tracks=\(tracks.count, privacy: .public)")
            return tracks
        }
    }
}
