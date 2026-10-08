import Testing
import Foundation
@testable import Cassette

/// The gapless decision is a pure function over the queue, the settings and the device, so the
/// whole arbitration table is asserted here instead of being felt out on a device.
@Suite("GaplessPolicy")
struct GaplessPolicyTests {
    @Test("AVPlayer teardown invalidates callbacks without resetting the cross-track cooldown")
    func systemPlaybackStateFencesLateEvents() {
        var playback = SystemPlaybackState()
        playback.isActive = true
        playback.recoveredCurrentStall = true
        playback.lastStallRecoveryAt = Date()
        let recoveryTime = playback.lastStallRecoveryAt
        playback.invalidateCallbacks()
        #expect(playback.generation == 1)
        playback.resetTrackRecovery()
        #expect(!playback.recoveredCurrentStall)
        #expect(playback.lastStallRecoveryAt == recoveryTime)
    }

    @Test("A cancelled bridge cannot retain a queued source or recovery flags")
    func bridgeStateResetsAsOneUnit() {
        var bridge = GaplessBridgeState()
        let song = DisplayableSong(id: "next", title: "Next")
        bridge.arm(next: song, source: .downloaded(URL(fileURLWithPath: "/tmp/next.flac")), epoch: 42)
        bridge.wasSelected = true
        bridge.recoveryWasRequested = true
        bridge.reset()
        #expect(bridge.next == nil)
        #expect(bridge.source == nil)
        #expect(bridge.epoch == 0)
        #expect(!bridge.wasSelected && !bridge.recoveryWasRequested)
    }

    private func decision(
        hasNext: Bool = true,
        crossfade: Double = 0,
        crossfadeDisabledForAlbumPairs: Bool = true,
        isAlbumPair: Bool = false,
        requiresSystemPlayer: Bool = false,
        enabled: Bool = true,
        metered: Bool = false,
        local: Bool = false,
        allowMetered: Bool = false,
        allowsPrebuffer: Bool = true
    ) -> GaplessDecision {
        GaplessPolicy.decision(
            hasNextTrack: hasNext,
            crossfadeDuration: crossfade,
            crossfadeDisabledForAlbumPairs: crossfadeDisabledForAlbumPairs,
            isAlbumPair: isAlbumPair,
            requiresSystemPlayer: requiresSystemPlayer,
            gaplessEnabled: enabled,
            isMeteredNetwork: metered,
            nextSourceIsLocal: local,
            allowMeteredNetwork: allowMetered,
            deviceAllowsPrebuffer: allowsPrebuffer
        )
    }

    @Test("Any consecutive queue track bridges when nothing forbids it")
    func bridgesPlainQueueTransition() {
        // The feature: gapless is not limited to album siblings any more — a playlist, a shuffled
        // order and an Autoplay addition all transition seamlessly.
        #expect(decision() == .bridge)
        #expect(decision(metered: true, local: true) == .bridge)
        #expect(decision(metered: true, allowMetered: true) == .bridge)
    }

    @Test("Nothing follows the current track")
    func endOfQueueNeverBridges() {
        #expect(decision(hasNext: false) == .endOfQueue)
        #expect(decision(hasNext: false, crossfade: 5) == .endOfQueue)
    }

    @Test("Crossfade owns non-album transitions, and its album exemption is honored")
    func crossfadeArbitration() {
        #expect(decision(crossfade: 5) == .crossfade)
        #expect(decision(crossfade: 5, isAlbumPair: true) == .bridge)
        #expect(decision(crossfade: 5, crossfadeDisabledForAlbumPairs: false, isAlbumPair: true) == .crossfade)
    }

    @Test("Turning gapless off never changes crossfade behaviour")
    func gaplessFlagDoesNotAffectCrossfade() {
        #expect(decision(enabled: false) == .disabledByUser)
        #expect(decision(crossfade: 5, enabled: false) == .crossfade)
    }

    @Test("Multichannel / Atmos is routed away from the bridge")
    func systemPlayerNeverBridges() {
        #expect(decision(requiresSystemPlayer: true) == .requiresSystemPlayer)
        // Even a gapless album pair must restart through AVPlayer to keep its surround bed.
        #expect(decision(crossfade: 5, isAlbumPair: true, requiresSystemPlayer: true) == .requiresSystemPlayer)
    }

    @Test("Metered networks keep remote pre-buffering opt-in, local files always allowed")
    func meteredNetworkPolicy() {
        #expect(decision(metered: true) == .meteredNetwork)
        #expect(decision(metered: true, allowMetered: true) == .bridge)
        #expect(decision(metered: true, local: true, allowMetered: false) == .bridge)
    }

    @Test("A constrained device defers pre-buffering")
    func deviceBudgetDefersPrebuffer() {
        #expect(decision(allowsPrebuffer: false) == .deviceConstrained)
        // The data plan is checked first: the reason a user reads must be the one they can act on.
        #expect(decision(metered: true, allowsPrebuffer: false) == .meteredNetwork)
    }

    @Test("Gapless is on by default")
    func defaultsToEnabled() {
        #expect(GaplessSettings.defaultEnabled)
        #expect(GaplessConfig.default == GaplessConfig(isEnabled: true))
    }
}

/// The album-pair rule is shared by the bridge and the crossfade exemption.
@Suite("GaplessPolicy.isAlbumPair")
struct GaplessAlbumPairTests {
    @Test("Same album, next track number is an album pair")
    func albumSiblings() {
        #expect(GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 4
        ))
    }

    @Test("Different album, non-consecutive number or missing metadata is not")
    func nonAlbumPairs() {
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "B", nextTrackNumber: 4
        ))
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 5
        ))
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: nil, currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: 4
        ))
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: nil, nextTrackNumber: 4
        ))
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: nil,
            nextAlbumId: "A", nextTrackNumber: 4
        ))
        #expect(!GaplessPolicy.isAlbumPair(
            currentAlbumId: "A", currentTrackNumber: 3,
            nextAlbumId: "A", nextTrackNumber: nil
        ))
    }
}
