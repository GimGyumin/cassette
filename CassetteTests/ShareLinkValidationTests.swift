import Testing
import Foundation
@testable import Cassette

struct ShareLinkValidationTests {
    @Test @MainActor func dragSuppliesALoadableURL() async throws {
        let expected = URL(string: "https://music.example/share/123")!
        let provider = MusicShareDragProvider.make(title: "Song") { expected }
        #expect(provider.canLoadObject(ofClass: NSURL.self))
        let received: NSURL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let object = object as? NSURL { continuation.resume(returning: object) }
                else { continuation.resume(throwing: error ?? ShareError.invalidShareURL) }
            }
        }
        #expect(received as URL == expected)
    }

    @Test func onlyWebLinksAreShareable() {
        #expect(ShareService.validatedPublicURL("https://music.example/share/123") != nil)
        #expect(ShareService.validatedPublicURL("Song — Artist") == nil)
        #expect(ShareService.validatedPublicURL("/share/123") == nil)
        #expect(ShareService.validatedPublicURL("file:///private/song.flac") == nil)
        #expect(ShareService.validatedPublicURL(nil) == nil)
    }
}
