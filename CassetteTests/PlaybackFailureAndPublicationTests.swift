import AudioStreaming
import AVFoundation
import Foundation
import MediaPlayer
import Testing
import SwiftSonic
@testable import Cassette

@MainActor
@Suite("Playback failure and publication ordering", .serialized)
struct PlaybackFailureAndPublicationTests {
    @Test func failureClassificationKeepsTheUnderlyingCause() {
        let underlying = URLError(.userAuthenticationRequired)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(PlaybackFailure.classify(wrapped).kind == .authorization)
        #expect(PlaybackFailure.classify(URLError(.notConnectedToInternet)).kind == .network)
        #expect(PlaybackFailure.classify(AudioPlayerError.codecError).kind == .unsupported)
        #expect(PlaybackFailure.classify(nil, httpStatus: 404).kind == .missingMedia)
        #expect(PlaybackFailure.classify(CancellationError()).kind == .cancelled)
        #expect(PlaybackFailure.classify(NSError(domain: AVFoundationErrorDomain, code: AVError.decodeFailed.rawValue)).kind == .decoding)
        #expect(PlaybackFailure.classify(CassetteError.connectionFailed(underlying: SwiftSonicError.httpError(statusCode: 403, endpoint: "stream", serverHost: nil))).kind == .authorization)
        #expect(PlaybackFailure.classify(JellyfinClientError.authenticationRequired).kind == .authorization)
        #expect(PlaybackFailure.classify(SwiftSonicError.network(URLError(.cancelled))).kind == .cancelled)
        #expect(PlaybackFailure.classify(CassetteError.timeout).kind == .network)
    }

    @Test func recoveryPolicyHasABoundedRetryAndNeverRetriesAuthorization() {
        let network = PlaybackFailure.classify(URLError(.networkConnectionLost))
        #expect(PlaybackRecoveryPolicy.decide(network, permitsAudio: true, attempted: false, canRefresh: true) == .refreshSource)
        #expect(PlaybackRecoveryPolicy.decide(network, permitsAudio: true, attempted: true, canRefresh: true) == .terminal)
        #expect(PlaybackRecoveryPolicy.decide(network, permitsAudio: false, attempted: false, canRefresh: true) == .terminal)
        #expect(PlaybackRecoveryPolicy.decide(.classify(nil, httpStatus: 403), permitsAudio: true, attempted: false, canRefresh: true) == .terminal)
        #expect(PlaybackRecoveryPolicy.decide(.classify(CancellationError()), permitsAudio: true, attempted: false, canRefresh: true) == .ignore)
    }

    @Test func typedEngineFailureClosesTransportWithoutCallingItATimeout() async throws {
        let f = try AuditPlaybackFixture()
        f.engine.state = .error
        await f.player.armAuditSegmentAndTasks()
        await f.player.handleAudioError(.codecError)
        guard case .error(.playbackFailed(let failure)) = f.container.playerState.playbackState else {
            Issue.record("The codec cause was lost"); return
        }
        #expect(failure.kind == .unsupported)
        #expect(await f.player.progressTask == nil)
        #expect(await f.player.currentPlaySegmentStart == nil)
        await f.player.stop()
    }

    @Test func queuedOldErrorCannotOverwritePause() async throws {
        let f = try AuditPlaybackFixture()
        let old = await f.player.playbackContext
        await f.player.pause()
        f.engine.state = .error
        await f.player.handleAudioError(.codecError, expectedContext: old)
        #expect(f.container.playerState.playbackState == .paused)
        await f.player.stop()
    }

    @Test func oldPositionAndFullSnapshotCannotOverwriteTheNewOccurrence() async throws {
        let f = try AuditPlaybackFixture()
        let service = NowPlayingService(playerService: f.player, artworkImageCache: f.container.artworkImageCache)
        let first = await f.player.makePlaybackPublication()
        await service.publishTrackChange(snapshot("First", position: 0, publication: first))
        await f.player.pause()
        let second = await f.player.makePlaybackPublication()
        await service.publishTrackChange(snapshot("Second", position: 12, publication: second))
        await service.pushPosition(elapsed: 99, rate: 1, duration: 180, publication: first)
        await service.update(with: snapshot("First", position: 99, publication: first))
        await service.setPlaybackRate(1, publication: first)
        await service.stop(publication: first)
        #expect(await service.currentSong?.title == "Second")
        let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Second")
        #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue == 12)
        #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue == 0)
        await service.stop()
        await f.player.stop()
    }

    @Test func olderPublicationWithinTheSameCommandIsRejected() async throws {
        let f = try AuditPlaybackFixture()
        let service = NowPlayingService(playerService: f.player, artworkImageCache: f.container.artworkImageCache)
        let old = await f.player.makePlaybackPublication()
        let newer = await f.player.makePlaybackPublication()
        await service.publishTrackChange(snapshot("Current", position: 50, publication: newer))
        await service.update(with: snapshot("Old metadata", position: 0, publication: old))
        #expect(await service.currentSong?.title == "Current")
        #expect(await service.currentSong?.position == 50)
        await service.stop()
        await f.player.stop()
    }

    private func snapshot(_ title: String, position: Double, publication: PlaybackPublication) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, artist: nil, album: nil, duration: 180, position: position,
            playbackRate: 0, artworkURL: nil, artworkHeaders: [:], coverArtId: nil,
            isLiveStream: false, radioStationName: nil, isrc: nil, trackId: title,
            queueIndex: 0, queueCount: 1, publication: publication)
    }
}
