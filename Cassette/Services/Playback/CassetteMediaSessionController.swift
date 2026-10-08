// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

#if os(iOS)
import AppIntents
import Foundation
import NowPlaying
import Observation
import UIKit

/// iOS 27 Now Playing bridge. It supplements the existing MediaPlayer metadata
/// with typed music content and the AppEntity identifier Siri uses for
/// “this song”, follow-up actions, and Apple Watch handoff.
@available(iOS 27.0, *)
@MainActor
final class CassetteMediaSessionController {
    private struct ContentKey: Equatable {
        let serverId: UUID
        let trackId: String
        let title: String
        let artist: String?
        let album: String?
        let duration: TimeInterval
        let artworkURL: URL?
        let artworkHeaders: [String: String]
        let coverArtId: String?
        let isrc: String?
    }

    private let representation: CassetteMediaSessionRepresentation
    private let session: MediaSession<CassetteMediaSessionRepresentation>
    private var lastContentKey: ContentKey?
    private var relevantEntityId: String?
    /// The same cover cache the in-app player reads. Answering the artwork provider from it makes the
    /// lock screen / Control Center show exactly the cover the app shows — offline, after a
    /// credential re-entry, and without a second HTTP request for an image already on disk.
    private let artworkCache: ArtworkImageCache?
    private let preparedCoverIdProvider: (@MainActor (String?) -> String?)?

    init(player: any PlayerServiceProtocol, artworkCache: ArtworkImageCache? = nil, preparedCoverIdProvider: (@MainActor (String?) -> String?)? = nil) {
        let representation = CassetteMediaSessionRepresentation(player: player)
        self.representation = representation
        self.session = MediaSession(representation)
        self.artworkCache = artworkCache
        self.preparedCoverIdProvider = preparedCoverIdProvider
    }

    func invalidateArtwork() { lastContentKey = nil }

    func update(_ snapshot: NowPlayingSnapshot, serverId: UUID?) async {
        guard !snapshot.isLiveStream,
              let trackId = snapshot.trackId,
              let serverId else {
            if representation.content != nil { representation.content = nil }
            representation.playbackSnapshot = playbackSnapshot(for: snapshot)
            lastContentKey = nil
            if relevantEntityId != nil {
                relevantEntityId = nil
                try? await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
            }
            return
        }

        // Position-only snapshots deliberately omit artworkURL/headers. Treating that
        // omission as a content change recreates MusicContent without artwork whenever
        // the user seeks or playback is paused/resumed. Carry the resolved artwork
        // forward while the same track remains active.
        let previousKey = lastContentKey
        let isSameTrack = previousKey?.serverId == serverId
            && previousKey?.trackId == trackId
        let resolvedArtworkURL = snapshot.artworkURL
            ?? (isSameTrack ? previousKey?.artworkURL : nil)
        let resolvedArtworkHeaders = snapshot.artworkURL != nil
            ? snapshot.artworkHeaders
            : (isSameTrack ? (previousKey?.artworkHeaders ?? [:]) : snapshot.artworkHeaders)
        let resolvedCoverArtId = snapshot.effectiveCoverArtId ?? preparedCoverIdProvider?(snapshot.albumId)
            ?? (isSameTrack ? previousKey?.coverArtId : nil)

        let contentKey = ContentKey(
            serverId: serverId,
            trackId: trackId,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration,
            artworkURL: resolvedArtworkURL,
            artworkHeaders: resolvedArtworkHeaders,
            coverArtId: resolvedCoverArtId,
            isrc: snapshot.isrc
        )
        let contentChanged = contentKey != lastContentKey

        let song = DisplayableSong(
            id: trackId,
            title: snapshot.title,
            artist: snapshot.artist,
            albumName: snapshot.album,
            duration: snapshot.duration,
            coverArtId: snapshot.coverArtId,
            isrc: snapshot.isrc
        )
        let entity = CassetteSongEntity(song: song, serverId: serverId, loadRelations: false)
        if contentChanged {
            let identifier = EntityIdentifier(for: entity)
            var content = MusicContent(
                id: entity.id,
                songTitle: snapshot.title,
                artistName: CassetteEntityDisplay.artistName(snapshot.artist),
                albumName: snapshot.album ?? "",
                type: .audio,
                duration: snapshot.duration > 0 ? .finite(snapshot.duration) : nil,
                artwork: artwork(
                    url: resolvedArtworkURL,
                    headers: resolvedArtworkHeaders,
                    coverArtId: resolvedCoverArtId
                )
            )
            content.isrc = snapshot.isrc
            content.appEntityIdentifiers = [identifier]
            representation.content = content
            lastContentKey = contentKey
        }
        representation.playbackSnapshot = playbackSnapshot(for: snapshot)
        if contentChanged || relevantEntityId != entity.id {
            try? await RelevantEntities.shared.updateEntities([entity], for: .audio(.nowPlaying))
            relevantEntityId = entity.id
        }

        if session.canBecomeApplicationPrimary && !session.isApplicationPrimary {
            try? await session.requestToBecomeApplicationPrimary()
        }
    }

    /// Update only the time/rate portion of the native Now Playing session. Rebuilding
    /// MusicContent for a progress tick is expensive and can discard loaded artwork.
    func updatePlayback(elapsed: TimeInterval, rate: Float) {
        let state: MediaPlaybackSnapshot.PlaybackState = rate > 0
            ? .playing(rate: rate)
            : .paused
        representation.playbackSnapshot = MediaPlaybackSnapshot(
            state: state,
            elapsedTime: elapsed,
            timestamp: Date()
        )
    }

    func stop() async {
        representation.content = nil
        representation.playbackSnapshot = MediaPlaybackSnapshot(state: .stopped)
        lastContentKey = nil
        if relevantEntityId != nil {
            relevantEntityId = nil
            try? await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
        }
    }

    private func playbackSnapshot(for snapshot: NowPlayingSnapshot) -> MediaPlaybackSnapshot {
        let state: MediaPlaybackSnapshot.PlaybackState = snapshot.playbackRate > 0
            ? .playing(rate: snapshot.playbackRate)
            : .paused
        return MediaPlaybackSnapshot(
            state: state,
            elapsedTime: snapshot.isLiveStream ? nil : snapshot.position,
            timestamp: Date()
        )
    }

    private func artwork(
        url: URL?,
        headers: [String: String],
        coverArtId: String?
    ) -> Artwork? {
        // A cover id alone is enough now: the local cache answers even when no artwork URL was
        // resolved (offline playback, credential re-entry, an item whose cover URL is missing).
        guard let artworkID = coverArtId ?? url?.absoluteString else { return nil }
        let cache = artworkCache
        return Artwork(id: artworkID) { _ in
            // 1. The cover the in-app player is showing — memory, then disk, then the plain
            //    `{id}@hero` file a download wrote. This is what keeps the native Now Playing UI
            //    honest when there is no route to the server.
            if let coverArtId,
               let cache,
               let cached = await Self.cachedCover(coverArtId: coverArtId, cache: cache),
               let cgImage = cached.cgImage {
                return try ArtworkRepresentation(cgImage: cgImage)
            }
            // Native Now Playing can request an id-only cover after background auto-advance.
            // Use the authenticated cache pipeline even when no snapshot URL was supplied.
            if let coverArtId, let cache,
               let image = await cache.load(coverArtId: coverArtId, tier: .hero, allowNetwork: true, playbackPriority: true),
               let cgImage = image.cgImage {
                return try ArtworkRepresentation(cgImage: cgImage)
            }
            // 2. Otherwise fetch the resolved artwork URL.
            guard let url else { throw URLError(.resourceUnavailable) }
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                data = responseData
            }
            return try ArtworkRepresentation(data: data)
        }
    }

    /// Memory → persisted disk → the plain `{id}@hero` file. Deliberately no network: the URL
    /// fallback in `artwork(url:headers:coverArtId:)` covers that, after the local sources.
    nonisolated private static func cachedCover(
        coverArtId: String,
        cache: ArtworkImageCache
    ) async -> PlatformImage? {
        return await cache.load(coverArtId: coverArtId, tier: .hero, allowNetwork: false)
    }
}

@available(iOS 27.0, *)
@Observable
@MainActor
/// The `NowPlaying` framework declares `MediaSessionRepresentable` without an actor
/// isolation annotation, so this `@MainActor` representation emits
/// `#ConformanceIsolation` in Swift 5 language mode. Keeping the representation on
/// the main actor is the correct behaviour (the framework drives it from the same
/// process as the player); the warning is recorded as a known acceptable one in
/// `CONTRIBUTING.md` and disappears once the framework documents its isolation
/// contract (or the project moves to the Swift 6 language mode).
final class CassetteMediaSessionRepresentation: MediaSessionRepresentable {
    let id = "app.cassette.primary-audio-session"
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    let commands: [MediaCommand]

    init(player: any PlayerServiceProtocol) {
        commands = [
            .play { await player.resume() },
            .pause { await player.pause() },
            .togglePlayPause { await player.togglePlayPause() },
            .next { try await player.skipToNext() },
            .previous { try await player.skipToPrevious() },
            .seekToPosition { position in await player.seek(to: position) }
        ]
    }
}
#endif
