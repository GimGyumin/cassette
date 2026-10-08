import Foundation
import SwiftData
import Testing
@testable import Cassette

@Suite("Local account cleanup")
@MainActor
struct LocalAccountDataCleanupTests {
    @Test func favoritesUseItemFieldsAndKeepAccountsSeparate() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let context = ModelContext(container)
        let firstServer = UUID()
        let secondServer = UUID()
        context.insert(FavoriteRecord(itemType: .song, itemId: "track", starredDate: Date(), serverId: firstServer))
        context.insert(FavoriteRecord(itemType: .song, itemId: "track", starredDate: Date(), serverId: secondServer))
        try context.save()

        let itemId = "track"
        let type = FavoriteType.song.rawValue
        let matches = try context.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate {
            $0.itemId == itemId && $0.itemType == type
        }))
        #expect(matches.count == 2)
        #expect(matches.contains { $0.serverId == firstServer })
        #expect(matches.contains { $0.serverId == secondServer })
        #expect(!matches.contains { $0.id == "song:track" })
    }

    @Test func removesLocalLibraryRecordsWithoutDeletingAccountConfiguration() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let context = ModelContext(container)
        let server = ServerConfig(displayName: "Test", baseURL: "https://example.com",
                                  username: "test", isActive: true)
        context.insert(server)
        context.insert(FavoriteRecord(itemType: .album, itemId: "album", starredDate: Date(), serverId: server.id))
        context.insert(PinnedItem(itemType: .album, itemId: "album", displayName: "Album",
                                  displaySubtitle: "Artist", coverArtId: nil, serverId: server.id, sortOrder: 0))
        context.insert(SearchHistoryEntry(itemId: "album", itemType: "album", displayName: "Album",
                                          coverArtId: nil, serverId: server.id.uuidString))
        try context.save()

        try LocalAccountDataCleanup.clearRecords(in: container)
        let check = ModelContext(container)
        #expect(try check.fetchCount(FetchDescriptor<FavoriteRecord>()) == 0)
        #expect(try check.fetchCount(FetchDescriptor<PinnedItem>()) == 0)
        #expect(try check.fetchCount(FetchDescriptor<SearchHistoryEntry>()) == 0)
        // Account removal must go through ServerService to remove Keychain entries.
        #expect(try check.fetchCount(FetchDescriptor<ServerConfig>()) == 1)
        // Repeating a partially completed cleanup is safe.
        try LocalAccountDataCleanup.clearRecords(in: container)
    }
}
