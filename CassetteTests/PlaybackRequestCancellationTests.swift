import Foundation
import SwiftSonic
import Testing
@testable import Cassette

@MainActor
private final class SuspendedPlaybackResolver: MediaResolverProtocol {
    nonisolated let starts: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var cancelledIDs: Set<String> = []

    init() {
        (starts, continuation) = AsyncStream.makeStream()
    }

    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        continuation.yield(songId)
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            cancelledIDs.insert(songId)
            throw error
        }
        throw CassetteError.timeout
    }

    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource {
        throw CassetteError.timeout
    }
}

@MainActor
@Suite("Playback request cancellation", .serialized)
struct PlaybackRequestCancellationTests {
    private func makePlayer(
        container: AppContainer, resolver: SuspendedPlaybackResolver, engine: FakePlaybackEngine
    ) -> PlayerService {
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Playback test", baseURL: "https://example.invalid", username: "test"
        ))
        return PlayerService(
            state: container.playerState, mediaResolver: resolver,
            serverService: container.serverService, sessionService: container.sessionService,
            artworkImageCache: container.artworkImageCache, lyricsService: container.lyricsService,
            libraryService: container.libraryService, cacheService: container.cacheService,
            downloadService: container.downloadService, cacheSettings: container.cacheSettings,
            streamingSettings: container.streamingSettings, replayGainSettings: container.replayGainSettings,
            crossfadeSettings: container.crossfadeSettings, gaplessSettings: container.gaplessSettings,
            toastService: container.toastService, statsService: container.statsService,
            listenBrainzService: container.listenBrainzService, engine: engine
        )
    }

    private func song(_ id: String) -> DisplayableSong {
        DisplayableSong(
            id: id, title: id, artist: nil, albumId: nil, albumName: nil,
            artistId: nil, genre: nil, duration: 180, trackNumber: nil,
            isDownloaded: false, coverArtId: nil, audioFormat: nil,
            replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
    }

    @Test func latestSelectionCancelsPreviousResolveAndStopCancelsLatest() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = SuspendedPlaybackResolver()
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        var starts = resolver.starts.makeAsyncIterator()
        let queue = [song("first"), song("second")]
        let first = Task { try await player.play(tracks: queue, startIndex: 0) }
        let firstStarted = await starts.next()
        #expect(firstStarted == "first")
        let second = Task { try await player.play(tracks: queue, startIndex: 1) }
        let secondStarted = await starts.next()
        #expect(secondStarted == "second")
        try await first.value
        #expect(resolver.cancelledIDs.contains("first"))
        #expect(container.playerState.currentTrack?.id == "second")
        await player.stop()
        try await second.value
        #expect(resolver.cancelledIDs.contains("second"))
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
    }

    @Test func pauseDuringResolutionCannotStartAudioLater() async throws {
        let engine = FakePlaybackEngine()
        let container = try AppContainer(inMemory: true, engine: engine)
        let resolver = SuspendedPlaybackResolver()
        let player = makePlayer(container: container, resolver: resolver, engine: engine)
        var starts = resolver.starts.makeAsyncIterator()
        let request = Task { try await player.play(tracks: [song("paused")], startIndex: 0) }
        let pausedStarted = await starts.next()
        #expect(pausedStarted == "paused")
        await player.pause()
        try await request.value
        #expect(resolver.cancelledIDs.contains("paused"))
        #expect(container.playerState.playbackState == .paused)
        #expect(!engine.calls.contains { if case .play = $0 { return true }; return false })
    }
}
