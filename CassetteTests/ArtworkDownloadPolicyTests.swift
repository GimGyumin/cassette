import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import SwiftSonic
import Synchronization
import Testing
@testable import Cassette

nonisolated private final class ArtworkPolicyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated struct Record: Sendable {
        var requests: [URLRequest] = []
        var payloads: [String: Data] = [:]
        var holdsResponse = false
    }
    static let record = Mutex(Record())
    private let delivery = Mutex<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cover-policy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let data = Self.record.withLock { value in value.requests.append(request); return value.payloads[url.path] }
        let task = Task { [weak self] in
            while Self.record.withLock({ $0.holdsResponse }) {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !Task.isCancelled, let data else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery.withLock { $0 = task }
    }
    override func stopLoading() { delivery.withLock { $0?.cancel(); $0 = nil } }
}

@Suite("Shared original covers and cellular policy", .serialized) @MainActor
struct ArtworkDownloadPolicyTests {
    @Test func healthyPlaybackContinuesDownloadingCovers() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let player = PlayerState()
        player.playbackState = .playing
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            playerState: player, serverState: f.server.state,
            songCoverProvider: { ["song:track": "shared", "song:alternate": "alternate"] })
        let pass = Task { await preloader.downloadAllCovers() }
        defer { pass.cancel(); preloader.pauseAutomaticDownloads() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !preloader.state.isComplete, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(preloader.state.isComplete)
        await pass.value
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 2)
        #expect(player.playbackState == .playing)
    }

    @Test func unchangedIDsRepairDeletedAndCorruptOriginals() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let enabled = BulkArtworkPreference.isEnabled
        UserDefaults.standard.set(true, forKey: BulkArtworkPreference.key)
        defer { UserDefaults.standard.set(enabled, forKey: BulkArtworkPreference.key) }
        let directory = f.root.appendingPathComponent("coverarts")
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory,
            songCoverProvider: { ["song:a": "shared", "song:b": "alternate"] })
        defer { preloader.resetBookkeeping() }
        await preloader.downloadAllCovers()
        try #require(preloader.state.isComplete)
        let sid = try #require(f.server.state.activeServer?.id)
        let first = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID("shared"), serverId: sid))
        let second = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID("alternate"), serverId: sid))
        try FileManager.default.removeItem(at: first)
        try Data("not an image".utf8).write(to: second)
        preloader.reconcileChangedCovers()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // Downloads finish before the separate palette/inventory completion phase.
            // Wait for the pass itself, not the earlier download flag transition.
            if ArtworkPolicyProtocol.record.withLock({ $0.requests.count >= 4 }),
               preloader.state.isComplete, !preloader.state.isAnalyzingColors { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 4)
        #expect(preloader.state.isComplete)
        #expect(!preloader.state.isAnalyzingColors)
        #expect(preloader.state.alreadyPrepared == 0)
        #expect(CassetteBackgroundDownloads.isValidArtwork(at: first))
        #expect(CassetteBackgroundDownloads.isValidArtwork(at: second))
        // Valid originals must still be reused on a subsequent inventory pass.
        await preloader.downloadAllCovers()
        #expect(preloader.state.alreadyPrepared == 2)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 4)
    }

    @Test func bulkArtworkWaitsForPlaybackThenResumes() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let player = PlayerState()
        player.playbackState = .loading
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            playerState: player, serverState: f.server.state, songCoverProvider: { ["song:track": "shared"] })
        let pass = Task { await preloader.downloadAllCovers() }
        defer { pass.cancel(); preloader.pauseAutomaticDownloads() }
        let deadline = Date().addingTimeInterval(3)
        while preloader.state.total == 0, Date() < deadline { await Task.yield() }
        try #require(preloader.state.total == 1)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.isEmpty })
        player.playbackState = .paused
        await pass.value
        #expect(preloader.state.isComplete)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 1)
    }
    @Test func albumAndTracksShareContentButAlternateImagesAndLegacyTimestampsDoNot() {
        let album = "al-album_0123456789abcdef"
        let track = "mf-track_0123456789abcdef"
        let alternate = "mf-alternate_fedcba9876543210"
        let albumDTO = AlbumID3(id: "album", name: "Album", songCount: 3, duration: 300, coverArt: album)
        #expect(AlbumCoverPreloadService.coverIDs(for: [albumDTO], songCoverIDs: [track, alternate, track]) == [album, alternate])
        #expect(DownloadService.albumCoverArtIDs(albumCoverArtID: album, songCoverArtIDs: [track, nil, alternate]) == [album, alternate])
        #expect(ArtworkIdentity.key("mf-one_69a67e01") != ArtworkIdentity.key("mf-two_69a67e01"))
        let sid = UUID()
        #expect(DownloadService.coverStorageName(for: OriginalArtwork.storageID(album), serverId: sid)
            == DownloadService.coverStorageName(for: OriginalArtwork.storageID(track), serverId: sid))
        #expect(DownloadService.coverStorageName(for: track, serverId: sid)
            != DownloadService.coverStorageName(for: track, serverId: UUID()))
        let missing = DisplayableSong(id: "song", title: "Song", albumId: "album")
        #expect(missing.effectiveCoverArtId == "album")
    }

    @Test func differentTrackIDsWithSharedImageDownloadOnceAndResolveOffline() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let album = "al-album_0123456789abcdef", track = "mf-track_0123456789abcdef"
        let alternate = "mf-track_fedcba9876543210"
        let red = try png(red: 0.8, green: 0.1), green = try png(red: 0.1, green: 0.8)
        ArtworkPolicyProtocol.record.withLock { $0.payloads = ["/" + album: red, "/" + track: red, "/" + alternate: green] }
        async let first = f.cache.downloadOriginalAndCacheAsHero(coverArtId: album, cacheHero: false)
        async let second = f.cache.downloadOriginalAndCacheAsHero(coverArtId: track, cacheHero: false)
        let results = await (first, second)
        #expect(results.0 && results.1)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 1)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: alternate, cacheHero: false))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 2)
        let sid = try #require(f.server.state.activeServer?.id)
        let a = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID(album), serverId: sid))
        let b = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID(track), serverId: sid))
        #expect(a == b)
        f.server.state.isOnline = false
        #expect(await f.cache.load(coverArtId: track, tier: .hero, allowNetwork: false) != nil)
    }

    @Test func existingEntityCoverMigratesWithoutNetwork() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        let album = "al-album_0123456789abcdef", track = "mf-track_0123456789abcdef"
        let directory = f.root.appendingPathComponent("coverarts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent(DownloadService.legacyCoverStorageName(for: OriginalArtwork.storageID(album), serverId: sid))
        try png(red: 0.8, green: 0.1).write(to: old)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: album, cacheHero: false))
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: track, cacheHero: false))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.isEmpty })
    }
    @Test func identicalBytesAcrossOpaqueIDsShareStorageAndSurviveRemoval() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let sid = try #require(f.server.state.activeServer?.id)
        let red = try png(red: 0.8, green: 0.1), green = try png(red: 0.1, green: 0.8)
        let directory = f.root.appendingPathComponent("coverarts")
        func url(_ id: String) -> URL {
            directory.appendingPathComponent(DownloadService.coverStorageName(for: OriginalArtwork.storageID(id), serverId: sid))
        }
        for id in ["album", "track-a", "track-b"] {
            await f.downloads.persistCover(red, forId: OriginalArtwork.storageID(id), serverId: sid)
        }
        let originalIdentity = try #require(ArtworkContentStore.fileIdentity(url("album")))
        #expect(ArtworkContentStore.fileIdentity(url("track-a")) == originalIdentity)
        #expect(ArtworkContentStore.fileIdentity(url("track-b")) == originalIdentity)
        // Replacing one track cannot change any other hard-linked image.
        await f.downloads.persistCover(green, forId: OriginalArtwork.storageID("track-a"), serverId: sid)
        #expect(try Data(contentsOf: url("track-a")) == green)
        #expect(try Data(contentsOf: url("album")) == red)
        #expect(ArtworkContentStore.fileIdentity(url("track-a")) != originalIdentity)
        await f.downloads.removeCover(forId: OriginalArtwork.storageID("album"), serverId: sid)
        await f.downloads.persistCover(red, forId: OriginalArtwork.storageID("track-c"), serverId: sid)
        #expect(ArtworkContentStore.fileIdentity(url("track-c")) == originalIdentity)
        #expect(try Data(contentsOf: url("track-b")) == red)
        // A cleared directory must never be mistaken for an already installed image.
        try FileManager.default.removeItem(at: directory)
        await f.downloads.persistCover(red, forId: OriginalArtwork.storageID("track-c"), serverId: sid)
        #expect(try Data(contentsOf: url("track-c")) == red)
    }

    @Test func migratesLegacyDuplicateBytesAndPreservesDistinctCovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try png(red: 0.8, green: 0.1), green = try png(red: 0.1, green: 0.8)
        let old = directory.appendingPathComponent("legacy"), current = directory.appendingPathComponent("new@original-v1")
        let different = directory.appendingPathComponent("alternate@original-v1")
        try red.write(to: old); try red.write(to: current); try green.write(to: different)
        try ArtworkContentStore.reconcile(directory: directory)
        #expect(ArtworkContentStore.fileIdentity(old) == ArtworkContentStore.fileIdentity(current))
        #expect(ArtworkContentStore.fileIdentity(old) != ArtworkContentStore.fileIdentity(different))
        #expect(try Data(contentsOf: different) == green)
        try FileManager.default.removeItem(at: current)
        #expect(try Data(contentsOf: old) == red)
        try ArtworkContentStore.write(red, to: current)
        #expect(ArtworkContentStore.fileIdentity(old) == ArtworkContentStore.fileIdentity(current))
    }

    @Test func completedPassIsNotPresentedAgainWhileVerifyingExistingFiles() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("coverarts")
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory,
            songCoverProvider: { ["song:a": "shared", "song:b": "alternate"] })
        defer { preloader.resetBookkeeping() }
        await preloader.downloadAllCovers()
        try #require(preloader.state.isComplete)
        let requestCount = ArtworkPolicyProtocol.record.withLock { $0.requests.count }
        var phases: [LibraryPreparationPhase] = []
        preloader.reportPreparation = { phases.append($0.phase) }
        // Metadata discovery yields while completion remains visible and no download starts.
        let second = Task { await preloader.downloadAllCovers() }
        await Task.yield()
        #expect(preloader.state.isComplete)
        #expect(!preloader.state.isDownloading)
        await second.value
        #expect(preloader.state.isComplete)
        #expect(!phases.contains(.covers))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == requestCount)
    }

    @Test func relaunchRestoresValidatedUniqueCoversWithoutNetworkAndRepairsOnlyMissingFiles() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("coverarts")
        ArtworkPolicyProtocol.record.withLock { value in value.payloads["/also-shared"] = value.payloads["/shared"] }
        let covers: [String: String] = ["song:a": "shared", "song:b": "also-shared", "song:c": "alternate"]
        let original = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        var completedCount: Int?
        original.reportPreparation = { progress in
            if progress.phase == .complete { completedCount = progress.coversTotal }
        }
        await original.downloadAllCovers()
        try #require(original.state.isComplete)
        #expect(completedCount == 2)
        #expect(original.state.libraryTotal == 2) // Three entity IDs, two actual images.
        #expect(original.state.availableCompleted == 2)
        let count = ArtworkPolicyProtocol.record.withLock { $0.requests.count }
        #expect(count == 3)
        let restartedCache = ArtworkImageCache(downloadService: f.downloads, libraryService: f.library,
            serverService: f.server, session: f.session)
        let restarted = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: restartedCache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        await restarted.restoreCompletedInventory()
        #expect(restarted.state.isComplete)
        #expect(restarted.state.libraryTotal == 2)
        #expect(!restarted.state.isDownloading)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == count)
        await restarted.downloadAllCovers()
        #expect(restarted.state.isComplete)
        #expect(restarted.state.libraryTotal == 2)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == count)
        let sid = try #require(f.server.state.activeServer?.id)
        let alternate = directory.appendingPathComponent(DownloadService.coverStorageName(for: OriginalArtwork.storageID("alternate"), serverId: sid))
        try FileManager.default.removeItem(at: alternate)
        let repaired = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: restartedCache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        await repaired.restoreCompletedInventory()
        #expect(!repaired.state.isComplete)
        await repaired.downloadAllCovers()
        #expect(repaired.state.isComplete)
        #expect(repaired.state.libraryTotal == 2)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == count + 1)
        repaired.resetBookkeeping()
        let cleared = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: restartedCache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        await cleared.restoreCompletedInventory()
        #expect(!cleared.state.isComplete)
    }

    @Test func failedCompletionPersistenceDoesNotClaimSuccessAndRetryReusesImages() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("coverarts")
        let sid = try #require(f.server.state.activeServer?.id)
        let blockedRecord = directory.appendingPathComponent(".completed-originals-\(sid.uuidString).plist")
        try FileManager.default.createDirectory(at: blockedRecord, withIntermediateDirectories: true)
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory,
            songCoverProvider: { ["song:a": "shared", "song:b": "alternate"] })
        await preloader.downloadAllCovers()
        #expect(!preloader.state.isComplete)
        #expect(preloader.state.errorMessage != nil)
        let count = ArtworkPolicyProtocol.record.withLock { $0.requests.count }
        #expect(count == 2)
        try FileManager.default.removeItem(at: blockedRecord)
        await preloader.downloadAllCovers()
        #expect(preloader.state.isComplete)
        #expect(preloader.state.libraryTotal == 2)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == count)
        preloader.resetBookkeeping()
    }

    @Test func startupCleanupPreservesBulkOriginalsAndRestoresCompletionWithoutRedownload() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("coverarts")
        let covers: [String: String] = ["song:a": "shared", "song:b": "alternate"]
        let preload = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        await preload.downloadAllCovers()
        try #require(preload.state.isComplete)
        #expect(!preload.state.isDownloading)
        let count = ArtworkPolicyProtocol.record.withLock { $0.requests.count }
        let sid = try #require(f.server.state.activeServer?.id)
        let original = directory.appendingPathComponent(DownloadService.coverStorageName(for: OriginalArtwork.storageID("shared"), serverId: sid))
        let thumbnail = directory.appendingPathComponent(DownloadService.coverStorageName(for: "shared@thumb", serverId: sid))
        let hero = directory.appendingPathComponent(DownloadService.coverStorageName(for: "shared@hero", serverId: sid))
        let legacy = directory.appendingPathComponent("legacy-offline-cover")
        let bytes = try Data(contentsOf: original)
        try bytes.write(to: thumbnail); try bytes.write(to: hero); try bytes.write(to: legacy)
        let domain = "artwork-upgrade-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        AppContainer.invalidateCoverArtCacheIfNeeded(artworkCache: f.cache, coverArtsDirectory: directory, defaults: defaults)
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(!FileManager.default.fileExists(atPath: hero.path))
        #expect(try Data(contentsOf: legacy) == bytes)
        // This is the startup GC input when no audio has been pinned/downloaded.
        #expect(await f.downloads.garbageCollectOrphanedCovers(referencedIds: []) == 0)
        #expect(try Data(contentsOf: original) == bytes)
        let restarted = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        let progress = LibraryPreparationService()
        progress.receiveExternalProgress(.init(phase: .covers, coversCompleted: 1, coversTotal: 2))
        restarted.reportPreparation = { progress.receiveExternalProgress($0) }
        await restarted.restoreCompletedInventory()
        #expect(restarted.state.isComplete)
        #expect(!restarted.state.isDownloading)
        #expect(progress.phase == .complete)
        #expect(progress.progress.coversCompleted == progress.progress.coversTotal)
        await restarted.downloadAllCovers()
        #expect(restarted.state.isComplete)
        #expect(!restarted.state.isDownloading)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == count)
        // Explicit logout still removes all account artwork and bookkeeping.
        f.server.state.isSigningOut = true
        #expect(await f.downloads.garbageCollectOrphanedCovers(referencedIds: []) > 0)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let loggedOut = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory, songCoverProvider: { covers })
        await loggedOut.restoreCompletedInventory()
        #expect(!loggedOut.state.isComplete)
    }

    @Test func constrainedDeviceAnalyzesAlreadyDownloadedCoversWithoutNetwork() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let directory = f.root.appendingPathComponent("coverarts")
        let sid = try #require(f.server.state.activeServer?.id)
        let first = "al-colors-\(UUID())_0123456789abcdef"
        let alias = "mf-colors-\(UUID())_0123456789abcdef", second = "colors-second-\(UUID())"
        let red = try png(red: 0.8, green: 0.1), green = try png(red: 0.1, green: 0.8)
        await f.downloads.persistCover(red, forId: OriginalArtwork.storageID(first), serverId: sid)
        await f.downloads.persistCover(red, forId: OriginalArtwork.storageID(alias), serverId: sid)
        await f.downloads.persistCover(green, forId: OriginalArtwork.storageID(second), serverId: sid)
        let wasActive = CassettePerformance.budget.isAppActive
        PerformanceGovernor.shared.setAppActive(false)
        defer { PerformanceGovernor.shared.setAppActive(wasActive) }
        #expect(!CassettePerformance.allowsHeavyColorAnalysis)
        #expect(ColorCache.palette(for: first) == nil)
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache,
            serverState: f.server.state, coversDirectory: directory,
            songCoverProvider: { ["song:a": first, "song:b": alias, "song:c": second] })
        await preloader.downloadAllCovers()
        #expect(preloader.state.isComplete)
        #expect(!preloader.state.isAnalyzingColors)
        #expect(!preloader.state.isDownloading)
        #expect(preloader.state.colorsCompleted == 3)
        #expect(ColorCache.palette(for: first) != nil)
        #expect(ColorCache.palette(for: second) != nil)
        #expect(ColorCache.palette(for: alias)?.packedBackground == ColorCache.palette(for: first)?.packedBackground)
        #expect(ColorCache.palette(for: second)?.packedBackground != ColorCache.palette(for: first)?.packedBackground)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.isEmpty })
        let persisted = UserDefaults.standard.dictionary(forKey: "cassette.artworkPalette.cache.v8")
        #expect(persisted?[first] != nil)
        #expect(persisted?[alias] != nil)
        #expect(persisted?[second] != nil)
        preloader.resetBookkeeping()
    }

    private struct Fixture {
        let root: URL
        let server: MockServerService
        let library: SearchLibraryStub
        let downloads: DownloadService
        let cache: ArtworkImageCache
        let session: URLSession
    }

    private func png(red: CGFloat, green: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Fixture", baseURL: "https://cover-policy.test", username: "u"))
        server.credentials = ServerCredentials(password: "fixture", customHeaders: ["X-Cover": "fixture"])
        server.musicClient = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://cover-policy.test")!,
            username: "u", password: "fixture"), retryPolicy: .none)
        let downloads = DownloadService(serverService: server, modelContainer: try .cassette(inMemory: true),
            toastService: ToastService(), journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")), storageDirectory: root)
        let library = SearchLibraryStub()
        library.coverURLOperation = { id, _ in URL(string: "https://cover-policy.test/\(id)") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkPolicyProtocol.self]
        let session = URLSession(configuration: config)
        let cache = ArtworkImageCache(downloadService: downloads, libraryService: library, serverService: server, session: session)
        ArtworkPolicyProtocol.record.withLock { $0 = .init() }
        let red = try png(red: 0.8, green: 0.1), green = try png(red: 0.1, green: 0.8)
        ArtworkPolicyProtocol.record.withLock { $0.payloads = ["/shared": red, "/alternate": green] }
        return Fixture(root: root, server: server, library: library, downloads: downloads, cache: cache, session: session)
    }

    private func waitForRequest() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ArtworkPolicyProtocol.record.withLock({ $0.requests.isEmpty }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(ArtworkPolicyProtocol.record.withLock { !$0.requests.isEmpty })
    }

    @Test func expensiveWiFiIsAllowedAndOldCellularMessageClears() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        f.server.state.isExpensive = true
        f.server.state.isCellularConnection = true
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache, serverState: f.server.state)
        await preloader.downloadAllCovers()
        #expect(preloader.state.errorMessage != nil)
        f.server.state.isCellularConnection = false
        #expect(f.server.state.isExpensive)
        preloader.resumeArtworkAfterNetworkChange()
        #expect(preloader.state.errorMessage == nil)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 1)
        #expect(f.cache.allowsNetworkDownloads)
    }

    @Test func concurrentConsumersDownloadOneOriginalAndKeepAlternateArtwork() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        ArtworkPolicyProtocol.record.withLock { $0.holdsResponse = true }
        let first = Task { await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false) }
        try await waitForRequest()
        let second = Task { await f.cache.downloadOriginalAndCacheAsHero(coverArtId: " shared ", cacheHero: true) }
        for _ in 0..<10 { await Task.yield() }
        ArtworkPolicyProtocol.record.withLock { $0.holdsResponse = false }
        let results = await (first.value, second.value)
        #expect(results.0 && results.1)
        #expect(f.cache.cachedImage(for: "shared", tier: .hero) != nil)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 1)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared"))
        #expect(await f.cache.load(coverArtId: "shared", tier: .thumb, allowNetwork: false) != nil)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "alternate", cacheHero: false))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 2)
        let sid = try #require(f.server.state.activeServer?.id)
        let shared = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID("shared"), serverId: sid))
        let alternate = try #require(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID("alternate"), serverId: sid))
        #expect(try Data(contentsOf: shared) != Data(contentsOf: alternate))
    }

    @Test func cancellingOneOriginalConsumerKeepsTheOtherConsumerAlive() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        let first = Task { await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false) }
        try await waitForRequest()
        let second = Task { await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: true) }
        for _ in 0..<10 { await Task.yield() }
        first.cancel()
        #expect(await first.value == false)
        #expect(await second.value)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 1)
    }

    @Test func cellularLoadsUseSavedImagesAndStartNoAutomaticRequest() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        f.server.state.isExpensive = true
        f.server.state.isCellularConnection = true
        #expect(await f.cache.load(coverArtId: "shared") == nil)
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared") == false)
        let sid = try #require(f.server.state.activeServer?.id)
        await f.downloads.persistCover(try png(red: 0.8, green: 0.1), forId: OriginalArtwork.storageID("shared"), serverId: sid)
        #expect(await f.cache.load(coverArtId: "shared", tier: .hero) != nil)
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.isEmpty })
        let preloader = AlbumCoverPreloadService(libraryService: f.library, artworkImageCache: f.cache, serverState: f.server.state)
        await preloader.downloadAllCovers()
        #expect(!preloader.state.isDownloading && preloader.state.total == 0)
        #expect(preloader.state.errorMessage != nil)
    }

    @Test func cancellingTheLastConsumerDrainsTheRequestAndAllowsARetry() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        ArtworkPolicyProtocol.record.withLock { $0.holdsResponse = true }
        let pending = Task { await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false) }
        try await waitForRequest()
        pending.cancel()
        #expect(await pending.value == false)
        let sid = try #require(f.server.state.activeServer?.id)
        #expect(await f.downloads.localCoverArtURL(forId: OriginalArtwork.storageID("shared"), serverId: sid) == nil)
        ArtworkPolicyProtocol.record.withLock { $0.holdsResponse = false }
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false))
        #expect(ArtworkPolicyProtocol.record.withLock { $0.requests.count } == 2)
    }

    @Test func returningToWiFiCanFetchImmediatelyAndRequestsEnforceThePolicy() async throws {
        let f = try fixture()
        defer { f.session.invalidateAndCancel(); try? FileManager.default.removeItem(at: f.root) }
        f.server.state.isExpensive = true
        f.server.state.isCellularConnection = true
        #expect(await f.cache.load(coverArtId: "shared") == nil)
        f.server.state.isExpensive = false
        f.server.state.isCellularConnection = false
        #expect(await f.cache.downloadOriginalAndCacheAsHero(coverArtId: "shared", cacheHero: false))
        let request = try #require(ArtworkPolicyProtocol.record.withLock { $0.requests.first })
        #expect(!request.allowsCellularAccess && request.allowsExpensiveNetworkAccess)
        #expect(request.value(forHTTPHeaderField: "X-Cover") == "fixture")
        let config = URLSessionConfiguration.default
        ArtworkNetworkPolicy.configure(config)
        #expect(!config.allowsCellularAccess && config.allowsExpensiveNetworkAccess)
    }
}
