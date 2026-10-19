import Foundation
import MediaPlayer
import Testing
@testable import Cassette

@Suite("System seek and Now Playing clock", .serialized) @MainActor
struct NowPlayingSeekClockTests {
    private func snapshot(position: Double, rate: Float, timestamp: Date = Date(), artworkURL: URL? = nil) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: "Clock", artist: nil, album: nil, duration: 180, position: position,
            playbackRate: rate, artworkURL: artworkURL, artworkHeaders: [:], coverArtId: nil,
            isLiveStream: false, radioStationName: nil, isrc: nil, trackId: "clock", timestamp: timestamp)
    }

    @Test func periodicPositionAndZeroSeekUpdateTheArtworkSnapshotWithoutAnArtworkURL() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = NowPlayingService(playerService: MockPlayerService(), artworkImageCache: container.artworkImageCache)
        await service.publishTrackChange(snapshot(position: 0, rate: 1))
        await service.pushPosition(elapsed: 72, rate: 1, duration: 180)
        #expect(await service.currentSong?.position == 72)
        await service.update(with: snapshot(position: 0, rate: 0))
        let latest = try #require(await service.currentSong)
        #expect(latest.position == 0)
        #expect(latest.playbackRate == 0)
        #expect(latest.projectingPlayback(to: latest.timestamp.addingTimeInterval(10)).position == 0)
        let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue == 0)
        #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue == 0)
        await service.stop()
    }

    @Test func artworkRepublishingUsesTheCurrentClockAndHonorsPause() {
        let time = Date(timeIntervalSince1970: 100)
        let cover = URL(string: "https://example.invalid/cover")!
        let old = snapshot(position: 0, rate: 1, timestamp: time, artworkURL: cover)
        let current = snapshot(position: 60, rate: 1, timestamp: time.addingTimeInterval(60)).preservingArtwork(from: old)
        let republished = current.projectingPlayback(to: time.addingTimeInterval(62))
        #expect(republished.position == 62)
        #expect(republished.artworkURL == cover)
        #expect(republished.timestamp == time.addingTimeInterval(62))
        let paused = current.updatingPlayback(position: 0, rate: 0, duration: 180, timestamp: time.addingTimeInterval(63))
        #expect(paused.projectingPlayback(to: time.addingTimeInterval(100)).position == 0)
    }

    @Test func cancelledSystemCallerStillCompletesAnAcceptedZeroSeek() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let player = MockPlayerService()
        player.seekDelay = .milliseconds(100)
        let service = NowPlayingService(playerService: player, artworkImageCache: container.artworkImageCache)
        let caller = Task { await service.seekFromSystem(to: 0) }
        caller.cancel()
        await caller.value
        #expect(player.seekCalledWith == 0)
        #expect(player.seekCompletedWith == 0)
        #expect(!player.seekWasCancelled)
        await service.stop()
    }
}
