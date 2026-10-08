import Foundation
import SwiftData
import Testing
@testable import Cassette

@Suite("Playback session write batching")
@MainActor
struct PlaybackSessionServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: PlaybackSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private let songs = [DisplayableSong(id: "a", title: "First", duration: 180),
                         DisplayableSong(id: "b", title: "Second", duration: 220)]

    private func payload(index: Int = 0, position: Double = 0) -> SessionPayload {
        SessionPayload(currentIndex: index, currentPosition: position, queue: songs,
                       currentTrack: songs[index], repeatMode: .off)
    }

    private func snapshot(_ container: ModelContainer) throws -> (position: Double, queue: Data, updated: Date, track: String?) {
        let context = ModelContext(container)
        let session = try #require(context.fetch(FetchDescriptor<PlaybackSession>()).first)
        return (session.currentPosition, session.queueData, session.lastUpdated, session.currentTrackId)
    }

    @Test("Identical snapshots don't create a new disk/CloudKit update")
    func skipsUnchangedSnapshot() async throws {
        let container = try container()
        let service = PlaybackSessionService(modelContainer: container)
        await service.save(playerState: payload(position: 12))
        let first = try snapshot(container)
        await service.save(playerState: payload(position: 12))
        let second = try snapshot(container)
        #expect(second.updated == first.updated)
        #expect(second.queue == first.queue)
    }

    @Test("Position and next-track checkpoints preserve the queue and reset position deduplication")
    func checkpointsAndTrackChanges() async throws {
        let container = try container()
        let service = PlaybackSessionService(modelContainer: container)
        await service.save(playerState: payload(position: 30))
        let first = try snapshot(container)
        await service.savePosition(60)
        #expect(try snapshot(container).queue == first.queue)
        await service.save(playerState: payload(index: 1))
        await service.savePosition(60)
        let next = try snapshot(container)
        #expect(next.position == 60)
        #expect(next.track == "b")
        #expect(next.queue == first.queue)
        await service.savePosition(.nan)
        await service.savePosition(.infinity)
        await service.savePosition(-10)
        #expect(try snapshot(container).updated == next.updated)
        let restored = await service.loadRestoredSession()
        #expect(restored?.queue == songs)
        #expect(restored?.currentIndex == 1)
        #expect(restored?.currentPosition == 60)
    }

    @Test("A newer synced session cannot fool the local queue/no-op cache")
    func cloudWinnerInvalidatesCache() async throws {
        let container = try container()
        let service = PlaybackSessionService(modelContainer: container)
        await service.save(playerState: payload(position: 12))
        let context = ModelContext(container)
        let other = DisplayableSong(id: "remote", title: "Remote queue")
        let synced = PlaybackSession(queue: [other], currentTrack: other)
        synced.lastUpdated = Date().addingTimeInterval(60)
        context.insert(synced)
        try context.save()
        await service.save(playerState: payload(position: 12))
        let restored = await service.loadRestoredSession()
        #expect(restored?.queue == songs)
        #expect(restored?.currentPosition == 12)
    }

    @Test("Clearing a session also clears write deduplication")
    func clearThenSaveAgain() async throws {
        let container = try container()
        let service = PlaybackSessionService(modelContainer: container)
        await service.save(playerState: payload(position: 12))
        await service.clear()
        await service.save(playerState: payload(position: 12))
        let restored = await service.loadRestoredSession()
        #expect(restored?.queue == songs)
        #expect(restored?.currentPosition == 12)
    }
}
