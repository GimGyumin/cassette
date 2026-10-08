import Foundation
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Off-main song preparation")
struct SongPreparationTests {
    @Test func largeQueueKeepsOrderDuplicatesAndPerTrackMetadata() async throws {
        let entries = try JSONDecoder().decode([Song].self, from: JSONSerialization.data(withJSONObject:
            (0..<4096).map { index in
                ["id": "song-\(index % 100)", "title": "Track \(index)", "coverArt": "cover-\(index)",
                 "explicitStatus": index.isMultiple(of: 2) ? "explicit" : "notExplicit"]
            }
        ))
        let prepared = try await DisplayableSong.prepare(entries, downloadedIDs: ["song-0"])
        #expect(prepared.count == entries.count)
        #expect(prepared.map(\.id) == entries.map(\.id))
        #expect(prepared.map(\.title) == entries.map(\.title))
        #expect(prepared[100].isDownloaded)
        #expect(!prepared[101].isDownloaded)
        #expect(prepared[100].coverArtId == "cover-100")
        #expect(prepared[100].explicitStatus == "explicit")
    }

    @Test func cancelledPreparationDoesNotPublishAResult() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await DisplayableSong.prepare([], downloadedIDs: [])
                Issue.record("Cancelled preparation returned a list")
            } catch is CancellationError {
                // Expected: no stale result is delivered to the view model.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        await task.value
    }
}
