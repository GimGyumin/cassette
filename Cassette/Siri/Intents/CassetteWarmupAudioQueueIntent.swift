// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// Short-lived handoff between the system's warmup and play intents. Warmup must not
/// mutate the live queue: doing so left stale tracks behind when Siri cancelled or a
/// later playback step failed, which could make every following request fail or play
/// an unrelated item.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
enum SiriPlaybackWarmupStore {
    private struct Entry {
        let entityId: CassetteEntityID
        let tracks: [DisplayableSong]
        let createdAt: Date
    }

    private static var entry: Entry?
    private static let lifetime: TimeInterval = 30

    static func store(_ tracks: [DisplayableSong], for entityId: CassetteEntityID) {
        entry = Entry(entityId: entityId, tracks: tracks, createdAt: Date())
    }

    static func consume(for entityId: CassetteEntityID) -> [DisplayableSong]? {
        guard let current = entry else { return nil }
        entry = nil
        guard current.entityId == entityId,
              Date().timeIntervalSince(current.createdAt) <= lifetime else { return nil }
        return current.tracks
    }

    static func clear() { entry = nil }
}

/// Adopts the `.audio.warmupAudioQueue` schema. Primes the playback queue for an
/// item without starting playback, returning the schema's marker result.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.warmupAudioQueue)
struct CassetteWarmupAudioQueueIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Warm Up Audio Queue"

    // MARK: Schema parameters

    var audioEntity: CassetteAudioItem
    @Parameter(default: [])
    var playbackAttributes: Set<CassettePlaybackAttributes>

    // MARK: Perform

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CassetteWarmupAudioQueueResult> {
        let tracks = try await resolveTracks()
        guard !tracks.isEmpty else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.noAudioEntity)
        }
        guard let id = audioEntity.entityID else {
            throw AppIntentError(wrapping: CassetteAudioIntentError.noAudioEntity)
        }
        SiriPlaybackWarmupStore.store(tracks, for: id)

        return .result(value: CassetteWarmupAudioQueueResult())
    }

    // MARK: Resolution

    @MainActor
    private func resolveTracks() async throws -> [DisplayableSong] {
        await SiriBridge.waitUntilReady()
        guard let catalog = await SiriBridge.catalogProvider?() else { return [] }
        guard let id = audioEntity.entityID else { return [] }
        switch audioEntity {
        case .song:
            if let track = await catalog.playableSong(id: id) { return [track] }
            return []
        case .album:
            return await catalog.playableSongs(inAlbum: id)
        case .artist:
            return await catalog.playableSongs(byArtist: id)
        case .playlist:
            return await catalog.playableSongs(inPlaylist: id)
        }
    }
}
