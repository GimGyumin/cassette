// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import AppIntents
import Foundation

/// Publishes Siri's current-song relevance without creating another playback
/// session. NowPlayingService's MediaPlayer API owns system metadata/commands.
@available(iOS 27.0, *)
@MainActor
final class CassetteNowPlayingEntityPublisher {
    private struct Key: Equatable {
        let serverId: UUID
        let trackId: String
        let title: String
        let artist: String?
        let album: String?
    }
    private var lastKey: Key?

    func update(_ snapshot: NowPlayingSnapshot, serverId: UUID?, isCurrent: @MainActor () -> Bool) async {
        guard isCurrent() else { return }
        guard !snapshot.isLiveStream, let trackId = snapshot.trackId, let serverId else {
            await stop(isCurrent: isCurrent)
            return
        }
        let key = Key(serverId: serverId, trackId: trackId, title: snapshot.title,
                      artist: snapshot.artist, album: snapshot.album)
        guard key != lastKey else { return }
        let song = DisplayableSong(id: trackId, title: snapshot.title, artist: snapshot.artist,
            albumName: snapshot.album, duration: snapshot.duration, coverArtId: snapshot.coverArtId,
            isrc: snapshot.isrc)
        let entity = CassetteSongEntity(song: song, serverId: serverId, loadRelations: false)
        try? await RelevantEntities.shared.updateEntities([entity], for: .audio(.nowPlaying))
        guard isCurrent() else { return }
        lastKey = key
    }

    func stop(isCurrent: @MainActor () -> Bool) async {
        guard isCurrent(), lastKey != nil else { return }
        lastKey = nil
        try? await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
    }
}
#endif
