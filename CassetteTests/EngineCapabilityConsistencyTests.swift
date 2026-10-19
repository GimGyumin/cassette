import Foundation
import Testing
@testable import Cassette

@MainActor
@Suite(.serialized)
struct EngineCapabilityConsistencyTests {
    private let config = ReplayGainConfig(enabled: true, mode: .track, preAmp: 0, preventClipping: true)

    @Test func nativeGainAttenuatesWithoutClaimingUnsupportedBoost() {
        let native = EngineCapabilities(native: true, wirelessRoute: false)
        let pcm = EngineCapabilities(native: false, wirelessRoute: false)
        #expect(abs(native.nativeGainMultiplier(requested: -6) - 0.501187) < 0.000001)
        #expect(native.nativeGainMultiplier(requested: 6) == 1)
        #expect(pcm.appliedGainDB(requested: 6) == 6)
        let boosted = PlaybackGainState(enabled: true, hasMetadata: true, requestedDB: 6)
        #expect(boosted.status(capabilities: native) == .nativeBoostUnavailable)
        #expect(boosted.status(capabilities: pcm) == .applied)
        #expect(PlaybackGainState(enabled: true).status(capabilities: native) == .noMetadata)
    }

    @Test func gainAndFadeUseIndependentVolumeFactors() async throws {
        let f = try AuditPlaybackFixture()
        let url = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "SilentMP3", withExtension: "mp3"))
        await f.player.installAuditNativeSource(url)
        await f.player.setEngineVolume(0.8)
        let track = DisplayableSong(id: "gain", title: "Gain", duration: 20, replayGainTrackGain: -6)
        let context = await f.player.playbackContext
        await f.player.applyReplayGain(track: track, config: config, context: context)
        #expect(abs(f.player.systemEngine.volume - 0.8 * 0.501187) < 0.00001)
        await f.player.setEngineVolume(0.4)
        #expect(abs(f.player.systemEngine.volume - 0.4 * 0.501187) < 0.00001)
        #expect(abs(await f.player.engineVolume() - 0.4) < 0.00001)
        await f.player.applyReplayGain(track: nil, config: config, context: context)
        #expect(abs(f.player.systemEngine.volume - 0.4) < 0.00001)
        await f.player.stop()
    }

    @Test func bothEnginesShareFadeRoutePolicy() {
        for native in [false, true] {
            #expect(EngineCapabilities(native: native, wirelessRoute: false).supportsSequentialFades)
            #expect(!EngineCapabilities(native: native, wirelessRoute: true).supportsSequentialFades)
            #expect(!EngineCapabilities(native: native, wirelessRoute: false).supportsOverlappingCrossfade)
        }
    }

    @Test func fadeInWaitsForAudibleConfirmationAndPauseRestoresVolume() async throws {
        let f = try AuditPlaybackFixture()
        f.container.playerState.playbackState = .loading
        await f.player.armAuditFadeIn()
        #expect(await f.player.fadeInTask == nil)
        #expect(await f.player.engineVolume() == 0)
        await f.player.publishEnginePlaybackConfirmation()
        #expect(await f.player.pendingFadeInDuration == nil)
        #expect(await f.player.fadeInTask != nil)
        await f.player.pause()
        #expect(await f.player.fadeInTask == nil)
        #expect(await f.player.engineVolume() == f.player.restoredVolume)
        await f.player.stop()
    }

    @Test func pauseRejectsLateGainAndFadeWrites() async throws {
        let f = try AuditPlaybackFixture()
        let context = await f.player.playbackContext
        await f.player.pause()
        let volume = await f.player.engineVolume()
        #expect(!(await f.player.applyFadeVolume(0, context: context)))
        await f.player.applyReplayGain(track: DisplayableSong(id: "old", title: "Old", duration: 20, replayGainTrackGain: -20), config: config, context: context)
        #expect(await f.player.playbackGain.requestedDB == 0)
        #expect(await f.player.engineVolume() == volume)
        await f.player.stop()
    }
}

private final class TestBundleMarker {}

private extension PlayerService {
    func armAuditFadeIn() {
        pendingFadeInDuration = 2
        setEngineVolume(0)
    }
}
