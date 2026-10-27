import Foundation
import Observation
import SwiftData
import Testing
@testable import Cassette

@Suite("Release candidate cache integrity")
@MainActor
struct ReleaseCandidateCacheTests {
    @Test func emptyDataCannotReplacePlayableEntry() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheService(modelContainer: container, cacheDirectory: directory)
        let server = UUID()
        let bytes = Data(repeating: 42, count: 100)
        let url = try await cache.store(data: bytes, forSongId: "track", serverId: server, mimeType: "audio/flac")
        await #expect(throws: CocoaError.self) {
            _ = try await cache.store(data: Data(), forSongId: "track", serverId: server, mimeType: "audio/flac")
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await cache.usedBytes == 100)
    }

    @Test func changingCodecRemovesOnlyTheSupersededCacheFile() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheService(modelContainer: container, cacheDirectory: directory)
        let server = UUID()
        let otherServer = UUID()
        let oldURL = try await cache.store(data: Data([1, 2]), forSongId: "track", serverId: server, mimeType: "audio/flac")
        let otherURL = try await cache.store(data: Data([3, 4]), forSongId: "track", serverId: otherServer, mimeType: "audio/flac")
        let newURL = try await cache.store(data: Data([5, 6, 7]), forSongId: "track", serverId: server, mimeType: "audio/mpeg")
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try Data(contentsOf: newURL) == Data([5, 6, 7]))
        #expect(try Data(contentsOf: otherURL) == Data([3, 4]))
        #expect(await cache.trackCount == 2)
        #expect(await cache.usedBytes == 5)
        await cache.clearAllForServer(server)
        #expect(await cache.trackCount == 1)
        #expect(FileManager.default.fileExists(atPath: otherURL.path))
    }

    @Test func overlappingStoresAndClearsKeepFilesAndRecordsConsistent() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheService(modelContainer: container, cacheDirectory: directory)
        let server = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...60 {
                group.addTask {
                    if index.isMultiple(of: 7) { await cache.clearAudioTracksOnly() }
                    // A raw counter reaches '<' at 60 and correctly trips HTML-response rejection.
                    // Keep varied payload sizes under an audio signature instead.
                    let payload = Data("fLaC".utf8) + Data(repeating: UInt8(index), count: index)
                    _ = try await cache.store(data: payload,
                        forSongId: "track-\(index % 4)", serverId: server, mimeType: "audio/flac")
                }
            }
            try await group.waitForAll()
        }
        let records = try ModelContext(container).fetch(FetchDescriptor<CachedTrack>())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == Set(records.map(\.filePath)))
        #expect(Set(records.map(\.songId)).count == records.count)
        for record in records {
            let data = try Data(contentsOf: directory.appendingPathComponent(record.filePath))
            #expect(Int64(data.count) == record.fileSize)
        }
    }
}

@Suite("Release candidate settings")
@MainActor
struct ReleaseCandidateSettingsTests {
    @Test func injectedDefaultsAreMigratedAndReloadPublishesQualityChanges() throws {
        let suite = "rc-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("mp3_320", forKey: "cassette.streaming.wifi")
        let settings = StreamingSettings(defaults: defaults)
        #expect(settings.wifiFormat == .aac256)
        #expect(defaults.string(forKey: "cassette.streaming.wifi") == CacheFormat.aac256.rawValue)
        let changed = ObservationFlag()
        withObservationTracking {
            _ = settings.wifiFormat
            _ = settings.cellularFormat
            _ = settings.downloadFormat
        } onChange: {
            changed.mark()
        }
        defaults.set(CacheFormat.flacOriginal.rawValue, forKey: "cassette.streaming.wifi")
        defaults.set(CacheFormat.aac128.rawValue, forKey: "cassette.streaming.cellular")
        defaults.set(CacheFormat.aac256.rawValue, forKey: "cassette.streaming.download")
        settings.reloadFromDefaults()
        #expect(changed.value)
        #expect(settings.wifiFormat == .flacOriginal)
        #expect(settings.cellularFormat == .aac128)
        #expect(settings.downloadFormat == .aac256)
    }
}

nonisolated private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.withLock { changed = true } }
    var value: Bool { lock.withLock { changed } }
}

@Suite("Release candidate downloaded album identity")
@MainActor
struct DownloadedAlbumIdentityTests {
    @Test func identicalRemoteIDsOnDifferentServersRemainSeparate() {
        let first = UUID(), second = UUID()
        let record = DownloadedAlbum(albumId: "album", serverId: first, name: "Same Album",
            tracksCount: 1, totalTracksCount: 10)
        let tracks = [first, second, second].enumerated().map { index, server in
            DownloadedTrack(songId: "track-\(index)", serverId: server, albumId: "album",
                filePath: "fixture", fileSize: 1, mimeType: "audio/flac", title: "Track", album: "Same Album")
        }
        let albums = DownloadedAlbumMerger.merge(records: [record], tracks: tracks)
        #expect(albums.count == 2)
        #expect(Set(albums.map(\.id)).count == 2)
        #expect(albums.first { $0.serverId == first }?.downloadedTracksCount == 1)
        #expect(albums.first { $0.serverId == first }?.hasFullDownloadIntent == true)
        #expect(albums.first { $0.serverId == second }?.downloadedTracksCount == 2)
        #expect(albums.first { $0.serverId == second }?.hasFullDownloadIntent == false)
        #expect(albums.allSatisfy { $0.albumId == "album" })
    }
}

@Suite("Release candidate queue consistency")
@MainActor
struct QueueConsistencyTests {
    @Test func overlappingQueueEditsKeepTheCurrentTrackAndValidIndices() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let tracks = (0..<12).map { DisplayableSong(id: "\($0)", title: "Track \($0)") }
        container.playerState.queue = tracks
        container.playerState.currentIndex = 5
        container.playerState.currentTrack = tracks[5]
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    switch index % 4 {
                    case 0: await service.removeFromQueue(at: 11)
                    case 1: await service.clearQueueHistory()
                    case 2: await service.moveInQueue(fromIndex: 8, toIndex: 1)
                    default: await service.clearUpNext()
                    }
                }
            }
        }
        let state = container.playerState
        #expect(state.queue.indices.contains(state.currentIndex))
        #expect(state.queue[state.currentIndex].id == "5")
        await service.stop()
    }

    @Test func lateAutoplayResultsRespectCurrentPolicyAndDeduplicate() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        let current = DisplayableSong(id: "current", title: "Current")
        let next = DisplayableSong(id: "next", title: "Next")
        let state = container.playerState
        state.queue = [current]
        state.currentTrack = current
        state.isAutoExtendEnabled = false
        await service.applyAutoExtend([next], serverID: nil)
        #expect(state.queue == [current])
        state.isAutoExtendEnabled = true
        state.repeatMode = .one
        await service.applyAutoExtend([next], serverID: nil)
        #expect(state.queue == [current])
        state.repeatMode = .off
        await service.applyAutoExtend([next], serverID: UUID())
        #expect(state.queue == [current])
        await service.applyAutoExtend([current, next, next], serverID: nil)
        #expect(state.queue == [current, next])
        #expect(state.originalQueueEndIndex == 1)
        await service.stop()
    }
}

@Suite("Atomic performance policy")
struct AtomicPerformanceBudgetTests {
    @Test func allPolicyCombinationsRoundTrip() {
        for thermal in ThermalPressure.allCases {
            for flags in 0..<32 {
                let budget = PerformanceBudget.make(thermalPressure: thermal,
                    isLowPowerMode: flags & 1 != 0, isAppActive: flags & 2 != 0,
                    reduceMotion: flags & 4 != 0, isMemoryPressured: flags & 8 != 0,
                    liquidGlassOverride: flags & 16 != 0)
                #expect(PerformanceBudgetStore(budget).load() == budget)
            }
        }
    }

    @Test func concurrentReadersNeverObserveMixedPolicyInputs() async {
        let cool = PerformanceBudget.placeholder
        let hot = PerformanceBudget.make(thermalPressure: .critical, isLowPowerMode: true,
            isAppActive: false, reduceMotion: true, isMemoryPressured: true, liquidGlassOverride: true)
        let store = PerformanceBudgetStore(cool)
        await withTaskGroup(of: Bool.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<1000 {
                        store.store((worker + index).isMultiple(of: 2) ? cool : hot)
                        let snapshot = store.load()
                        if snapshot != cool && snapshot != hot { return false }
                    }
                    return true
                }
            }
            for await consistent in group { #expect(consistent) }
        }
    }
}
