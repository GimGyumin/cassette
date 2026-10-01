import Foundation
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Remote media identity compatibility")
@MainActor
struct MediaIdentityCompatibilityTests {
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
