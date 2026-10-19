import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Cassette

@MainActor
@Suite("Account-scoped playback persistence and reset", .serialized)
struct PlaybackSessionIdentityTests {
    @Test func lateCheckpointCannotWriteAnotherAccountTrackOrOccurrence() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = PlaybackSessionService(modelContainer: container)
        let a = UUID(), b = UUID()
        let song = DisplayableSong(id: "shared-id", title: "Song", duration: 180)
        let first = PlaybackCheckpointIdentity(accountID: a, trackID: song.id, queueIndex: 0, revision: "first")
        let repeated = PlaybackCheckpointIdentity(accountID: a, trackID: song.id, queueIndex: 0, revision: "repeat")
        let other = PlaybackCheckpointIdentity(accountID: b, trackID: song.id, queueIndex: 0, revision: "other")
        func payload(_ position: Double) -> SessionPayload {
            SessionPayload(currentIndex: 0, currentPosition: position, queue: [song], currentTrack: song, repeatMode: .off)
        }
        await service.save(playerState: payload(10), identity: first)
        await service.save(playerState: payload(20), identity: other)
        await service.save(playerState: payload(0), identity: repeated)
        await service.savePosition(99, identity: first)
        await service.savePosition(88, identity: PlaybackCheckpointIdentity(accountID: a, trackID: "wrong", queueIndex: 0, revision: "repeat"))
        #expect(await service.loadRestoredSession(accountID: a)?.currentPosition == 0)
        #expect(await service.loadRestoredSession(accountID: b)?.currentPosition == 20)
        await service.savePosition(45, identity: repeated)
        #expect(await service.loadRestoredSession(accountID: a)?.currentPosition == 45)
    }

    @Test func legacyRecoveryCopiesWithoutDeletingOrGuessingAnOwner() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = PlaybackSessionService(modelContainer: container)
        let song = DisplayableSong(id: "legacy", title: "Legacy", duration: 180)
        await service.save(playerState: SessionPayload(currentIndex: 0, currentPosition: 50,
            queue: [song], currentTrack: song, repeatMode: .all))
        let account = UUID()
        #expect(await service.loadRestoredSession(accountID: account) == nil)
        #expect(await service.hasLegacySession())
        let authority = PlaybackAuthority()
        let publication = PlaybackPublication(context: authority.snapshot, sequence: 1, authority: authority)
        #expect(await service.copyLegacySession(to: account, publication: publication))
        #expect(await service.loadRestoredSession(accountID: account)?.currentPosition == 50)
        #expect(await service.loadRestoredSession()?.queue == [song])
        #expect(await service.hasLegacySession())
        #expect(!((await service.copyLegacySession(to: account, publication: publication))))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlaybackSession>()) == 2)
    }

    @Test func diskStoreReopensBothLegacyAndScopedSessionsWithoutSchemaChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.store")
        let account = UUID()
        let song = DisplayableSong(id: "disk", title: "Disk", duration: 180)
        let payload = SessionPayload(currentIndex: 0, currentPosition: 30, queue: [song], currentTrack: song, repeatMode: .one)
        func open() throws -> ModelContainer {
            try ModelContainer(for: PlaybackSession.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        }
        let first = PlaybackSessionService(modelContainer: try open())
        await first.save(playerState: payload)
        let second = PlaybackSessionService(modelContainer: try open())
        #expect(await second.loadRestoredSession()?.currentPosition == 30)
        await second.save(playerState: payload, identity: PlaybackCheckpointIdentity(accountID: account, trackID: song.id, queueIndex: 0, revision: "disk"))
        let reopened = PlaybackSessionService(modelContainer: try open())
        #expect(await reopened.loadRestoredSession()?.queue == [song])
        #expect(await reopened.loadRestoredSession(accountID: account)?.queue == [song])
    }

    @Test func resetRebuildsAudioObjectsAndRetainsAPausedQueue() async throws {
        let f = try AuditPlaybackFixture()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SilentMP3.mp3")
        await f.player.installAuditNativeSource(url)
        let generation = await f.player.systemPlayback.generation
        await f.player.armAuditSegmentAndTasks()
        await f.player.resetAudioObjectsAfterMediaServicesReset()
        #expect(f.engine.calls.contains(.resetAudioObjects))
        #expect(!f.player.systemEngine.hasCurrentItem)
        #expect(f.container.playerState.currentTrack?.id == f.track.id)
        #expect(f.container.playerState.queue == [f.track])
        #expect(f.container.playerState.position == 60)
        #expect(f.container.playerState.playbackState == .paused)
        #expect(await f.player.progressTask == nil)
        await f.player.handleSystemEngineEvent(.timeControl(generation, AVPlayer.TimeControlStatus.playing.rawValue))
        #expect(f.container.playerState.playbackState == .paused)
        #expect(!f.engine.calls.contains(.resume))
        await f.player.stop()
    }
}
