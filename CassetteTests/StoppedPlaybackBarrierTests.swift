import Foundation
import Testing
@testable import Cassette

@MainActor private final class StopMetadataGate: NowPlayingServiceProtocol {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func start() async {}
    func stop() async {}
    func clearArtworkCache() async {}
    func update(with snapshot: NowPlayingSnapshot) async {}
    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async {}
    func setISRC(_ isrc: String) async {}
    func setPlaybackRate(_ rate: Float) async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func clearISRC() async {}
    func publishTrackChange(_ snapshot: NowPlayingSnapshot) async {}
    func reassertRemoteCommands() async {}
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Stopped playback cannot restart", .serialized) @MainActor
struct StoppedPlaybackBarrierTests {
    @Test func staleResumePlaySeekAndRestoreCannotSupersedeStopDuringMetadataCleanup() async throws {
        let fixture = try AuditPlaybackFixture()
        let gate = StopMetadataGate()
        _ = await fixture.player.beginSystemInterruption()
        await fixture.player.setNowPlayingService(gate)
        let stopping = Task { await fixture.player.stop() }
        let deadline = Date().addingTimeInterval(5)
        while !gate.entered, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard gate.entered else {
            gate.release(); await stopping.value
            Issue.record("Stop did not reach the controlled suspension")
            return
        }
        await fixture.player.resume()
        try await fixture.player.play(tracks: [fixture.track], startIndex: 0)
        await fixture.player.seek(to: 0)
        await fixture.player.restoreSession()
        await fixture.player.handleNetworkRestored()
        #expect(fixture.resolver.resolveCount == 0)
        #expect(await fixture.player.transport.intent == .stop)
        gate.release()
        await stopping.value
        #expect(fixture.container.playerState.currentTrack == nil)
        #expect(fixture.container.playerState.queue.isEmpty)
        #expect(fixture.container.playerState.playbackState == .idle)
        #expect(await fixture.player.stopBarrierCount == 0)
        #expect(!(await fixture.player.transport.interrupted))
        await fixture.player.resume()
        #expect(fixture.container.playerState.currentTrack == nil)
        #expect(await fixture.player.transport.intent == .stop)
    }

    @Test func signingOutRejectsNewSelectionsAndResume() async throws {
        let fixture = try AuditPlaybackFixture()
        fixture.container.serverState.isSigningOut = true
        await fixture.player.resume()
        try await fixture.player.play(tracks: [fixture.track], startIndex: 0)
        #expect(fixture.resolver.resolveCount == 0)
        await fixture.player.stop()
        #expect(fixture.container.playerState.currentTrack == nil)
        #expect(fixture.container.playerState.queue.isEmpty)
    }
}
