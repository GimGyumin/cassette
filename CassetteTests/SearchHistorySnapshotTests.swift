import Foundation
import SwiftData
import Testing
@testable import Cassette

@MainActor
struct SearchHistorySnapshotTests {
    @Test func snapshotsAreScopedBoundedAndUnaffectedByUnrelatedSaves() async throws {
        let modelContainer = try ModelContainer.cassette(inMemory: true)
        let context = modelContainer.mainContext
        let service = SearchHistoryService(container: modelContainer)
        for index in 0..<55 {
            let entry = SearchHistoryEntry(itemId: "track-\(index)", itemType: "album", displayName: "Album \(index)",
                coverArtId: "cover-\(index)", serverId: "one")
            entry.visitedAt = Date(timeIntervalSince1970: Double(index))
            context.insert(entry)
        }
        context.insert(SearchHistoryEntry(itemId: "other", itemType: "artist", displayName: "Other", coverArtId: nil, serverId: "two"))
        try context.save()
        let initial = await service.recent(serverId: "one")
        #expect(initial.count == 50)
        #expect(initial.first?.itemId == "track-54")
        #expect(initial.last?.itemId == "track-5")
        #expect(await service.recent(serverId: "two").count == 1)
        context.insert(ServerConfig(displayName: "Unrelated save", baseURL: "https://example.invalid", username: "user"))
        try context.save()
        #expect(await service.recent(serverId: "one") == initial)
        await service.record(itemId: "new", itemType: "album", displayName: "New", coverArtId: "new-art", serverId: "one")
        #expect(await service.recent(serverId: "one").first?.itemId == "new")
        await service.clear(serverId: "one")
        #expect(await service.recent(serverId: "one").isEmpty)
        #expect(await service.recent(serverId: "two").count == 1)
        #expect(initial.count == 50)
    }
}
