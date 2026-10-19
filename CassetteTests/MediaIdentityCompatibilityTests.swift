import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Remote media identity compatibility")
@MainActor
struct MediaIdentityCompatibilityTests {
    @Test func batchedDownloadIdentitiesPreserveAliasesAndServerScope() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let server = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("downloads/fixture"))
        let downloads = DownloadService(serverService: container.serverService, modelContainer: container.modelContainer,
            toastService: ToastService(), mediaIdentityService: container.mediaIdentityService,
            journal: BackgroundDownloadJournal(directory: directory.appendingPathComponent("journal")), storageDirectory: directory)
        container.modelContainer.mainContext.insert(DownloadedTrack(songId: "old", serverId: server,
            filePath: "fixture", fileSize: 1, mimeType: "audio/flac", title: "Song"))
        try container.modelContainer.mainContext.save()
        #expect(container.mediaIdentityService.registerAlias(oldID: "old", newID: "current", serverId: server,
            entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(await downloads.downloadedSongIds(serverId: server) == ["old", "current"])
        #expect(await downloads.downloadedSongIds(serverId: UUID()).isEmpty)
        #expect(container.mediaIdentityService.registerAlias(oldID: "current", newID: "newest", serverId: server,
            entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(await downloads.downloadedSongIds(serverId: server) == ["old", "current", "newest"])
    }

    @Test func backgroundCandidatesRefreshAfterAliasChangesAndStayScoped() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = MediaIdentityService(modelContainer: container)
        let server = UUID()
        #expect(await service.candidateRemoteIDsInBackground(for: "old", serverId: server, entityType: .coverArt) == ["old"])
        #expect(service.registerAlias(oldID: "old", newID: "middle", serverId: server, entityType: .coverArt, verificationSource: .serverResponse, confidence: 1))
        #expect(service.registerAlias(oldID: "middle", newID: "current", serverId: server, entityType: .coverArt, verificationSource: .serverResponse, confidence: 1))
        for id in ["old", "middle", "current"] {
            let candidates = await service.candidateRemoteIDsInBackground(for: id, serverId: server, entityType: .coverArt)
            #expect(Set(candidates) == ["old", "middle", "current"])
            #expect(candidates.first == id)
            #expect(Set(candidates) == Set(service.candidateRemoteIDs(for: id, serverId: server, entityType: .coverArt)))
        }
        #expect(await service.candidateRemoteIDsInBackground(for: "old", serverId: UUID(), entityType: .coverArt) == ["old"])
        #expect(await service.candidateRemoteIDsInBackground(for: "old", serverId: server, entityType: .song) == ["old"])
        #expect(service.registerAlias(oldID: "current", newID: "newest", serverId: server, entityType: .coverArt, verificationSource: .serverResponse, confidence: 1))
        #expect(Set(await service.candidateRemoteIDsInBackground(for: "old", serverId: server, entityType: .coverArt)) == ["old", "middle", "current", "newest"])
    }

    @Test func backgroundCandidatesRetainIdentityLegaciesWithoutAnAliasRow() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let server = UUID()
        container.mainContext.insert(RemoteMediaIdentity(serverId: server, entityType: .album,
            currentRemoteID: "current", legacyRemoteIDs: ["historic", "older"]))
        try container.mainContext.save()
        let service = MediaIdentityService(modelContainer: container)
        #expect(Set(await service.candidateRemoteIDsInBackground(for: "historic", serverId: server, entityType: .album)) == ["historic", "older", "current"])
        #expect(Set(await service.candidateRemoteIDsInBackground(for: "current", serverId: server, entityType: .album)) == ["historic", "older", "current"])
    }

    @Test func backgroundMenuQueriesReflectFavoriteAndPinWrites() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let server = ServerConfig(displayName: "Menu snapshot", baseURL: "https://example.invalid", username: "test")
        container.serverState.activeServer = ServerSnapshot(from: server)
        #expect(await container.favoritesService.isFavoriteInBackground(itemType: .album, itemId: "new") == false)
        #expect(await container.pinService.isPinnedInBackground(itemType: .album, itemId: "new") == false)
        container.modelContainer.mainContext.insert(FavoriteRecord(itemType: .album, itemId: "old", starredDate: Date(), serverId: server.id))
        try container.modelContainer.mainContext.save()
        #expect(container.mediaIdentityService.registerAlias(oldID: "old", newID: "new", serverId: server.id,
            entityType: .album, verificationSource: .serverResponse, confidence: 1))
        #expect(await container.favoritesService.isFavoriteInBackground(itemType: .album, itemId: "new"))
        try container.pinService.pin(itemType: .album, itemId: "new", displayName: "Album",
            displaySubtitle: "", coverArtId: nil, serverId: server.id)
        #expect(await container.pinService.isPinnedInBackground(itemType: .album, itemId: "new"))
        container.pinService.unpin(itemType: .album, itemId: "new")
        #expect(await container.pinService.isPinnedInBackground(itemType: .album, itemId: "new") == false)
    }

    @Test func aliasChainsCollapseAndRemainServerScoped() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = MediaIdentityService(modelContainer: container)
        let firstServer = UUID()
        let secondServer = UUID()

        #expect(service.registerAlias(oldID: "A", newID: "B", serverId: firstServer, entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(service.registerAlias(oldID: "B", newID: "C", serverId: firstServer, entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(service.resolveCurrentID("A", serverId: firstServer, entityType: .song) == "C")
        #expect(service.resolveCurrentID("B", serverId: firstServer, entityType: .song) == "C")
        #expect(service.registerAlias(oldID: "A", newID: "C", serverId: firstServer, entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(service.resolveCurrentID("A", serverId: secondServer, entityType: .song) == "A")
        #expect(!service.registerAlias(oldID: "C", newID: "A", serverId: firstServer, entityType: .song, verificationSource: .serverResponse, confidence: 1))
    }

    @Test func entityTypesHaveIndependentNamespaces() throws {
        let service = MediaIdentityService(modelContainer: try ModelContainer.cassette(inMemory: true))
        let server = UUID()
        #expect(service.registerAlias(oldID: "same", newID: "song-new", serverId: server, entityType: .song, verificationSource: .serverResponse, confidence: 1))
        #expect(service.resolveCurrentID("same", serverId: server, entityType: .album) == "same")
    }

    @Test func matcherPrefersExternalIDAndRejectsAmbiguousMetadata() {
        let download = snapshot(musicBrainzID: "mbid-1")
        let exact = song(id: "new", musicBrainzID: "MBID-1")
        let metadataOnly = song(id: "other")
        #expect(RemoteIdentityMatcher.match(download: download, candidates: [metadataOnly, exact])?.songID == "new")

        let ambiguous = snapshot(musicBrainzID: nil)
        #expect(RemoteIdentityMatcher.match(download: ambiguous, candidates: [song(id: "one"), song(id: "two")]) == nil)
    }

    @Test func matcherNeverUsesTitleAndArtistAlone() {
        var weak = snapshot(musicBrainzID: nil)
        weak = DownloadIdentitySnapshot(
            recordID: weak.recordID,
            historicalID: weak.historicalID,
            currentRemoteID: nil,
            albumID: nil,
            artistID: nil,
            coverArtID: nil,
            title: weak.title,
            artist: weak.artist,
            album: nil,
            discNumber: nil,
            trackNumber: nil,
            durationSeconds: nil,
            mediaPath: nil,
            musicBrainzID: nil,
            isrc: nil
        )
        #expect(RemoteIdentityMatcher.match(download: weak, candidates: [song(id: "new")]) == nil)
    }

    private func snapshot(musicBrainzID: String?) -> DownloadIdentitySnapshot {
        DownloadIdentitySnapshot(
            recordID: UUID(),
            historicalID: "old",
            currentRemoteID: nil,
            albumID: "old-album",
            artistID: "old-artist",
            coverArtID: "old-cover",
            title: "Song",
            artist: "Artist",
            album: "Album",
            discNumber: 1,
            trackNumber: 2,
            durationSeconds: 180,
            mediaPath: nil,
            musicBrainzID: musicBrainzID,
            isrc: nil
        )
    }

    private func song(id: String, musicBrainzID: String? = nil) -> Song {
        Song(
            id: id,
            title: "Song",
            album: "Album",
            artist: "Artist",
            track: 2,
            duration: 180,
            discNumber: 1,
            albumId: "new-album",
            artistId: "new-artist",
            musicBrainzId: musicBrainzID
        )
    }
}
