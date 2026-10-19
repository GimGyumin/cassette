import Foundation
import SwiftSonic
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Testing
@testable import Cassette

@MainActor
@Suite("Downloaded player artwork")
struct DownloadedPlayerArtworkTests {
    @Test func playbackUsesKnownAlbumCoverWhenTrackMetadataOmitsIt() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let server = ServerConfig(displayName: "Artwork fallback", baseURL: "https://example.invalid", username: "test")
        container.serverState.activeServer = ServerSnapshot(from: server)
        let album = AlbumID3(id: "fallback-album", name: "Album", songCount: 1, duration: 100, coverArt: "saved-album-cover")
        await container.libraryIndexService.registerAlbumVersions([album], serverId: server.id)
        let song = DisplayableSong(id: "metadata-without-cover", title: "Song", albumId: album.id)
        #expect(container.playbackCoverId(for: song) == "saved-album-cover")
        let alternate = DisplayableSong(id: "alternate", title: "Alternate", albumId: album.id, coverArtId: "alternate-track-cover")
        #expect(container.playbackCoverId(for: alternate) == "alternate-track-cover")
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        await container.downloadService.persistCover(data, forId: "saved-album-cover")
        defer { Task { await container.downloadService.removeCover(forId: "saved-album-cover", serverId: server.id) } }
        container.serverState.isExpensive = true
        container.serverState.isCellularConnection = true
        #expect(await container.artworkImageCache.load(coverArtId: container.playbackCoverId(for: song), tier: .hero) != nil)
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Other", baseURL: "https://other.invalid", username: "other"))
        // The other account may resolve its own album ID, never this account's cached mapping.
        #expect(container.playbackCoverId(for: song) == song.albumId)
    }

    @Test func permanentCoverIsAvailableWithoutNetworkOrTieredCache() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Artwork test", baseURL: "https://example.invalid", username: "test"
        ))
        let id = "downloaded-artwork-test-\(UUID().uuidString)"
        let data = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="
        ))
        await container.downloadService.persistCover(data, forId: id)
        container.serverState.isOnline = false

        // A freshly opened player has no RAM hit and no {id}@hero derivative. The permanent
        // download must be decoded locally for the selected offline account, without networking.
        let image = await container.artworkImageCache.load(coverArtId: id, tier: .hero, allowNetwork: false)
        await container.downloadService.removeCover(forId: id)
        #expect(image != nil)
        #expect(container.artworkImageCache.cached(for: id, tier: .hero) != nil)
    }
}


nonisolated private final class OriginalCoverProtocol: URLProtocol, @unchecked Sendable {
    static func originalBytes() -> Data {
        let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "original.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.originalBytes())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite("Original artwork persistence")
struct OriginalArtworkTests {
    @Test func originalReplacesStreamingThumbnailWithoutResizingStoredBytes() async throws {
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        container.serverState.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Original test", baseURL: "https://original.test", username: "test"))
        let id = "original-test-\(UUID().uuidString)"
        let small = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg=="))
        await container.downloadService.persistCover(small, forId: "\(id)@hero")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OriginalCoverProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let library = SearchLibraryStub()
        library.coverURL = URL(string: "https://original.test/cover")
        let cache = ArtworkImageCache(downloadService: container.downloadService, libraryService: library, session: session)
        let old = await cache.load(coverArtId: id, tier: .hero, allowNetwork: false)
        #expect(old?.size.width == 1)
        #expect(await cache.downloadOriginalAndCacheAsHero(coverArtId: id))
        #expect(library.coverSizes.count == 1 && library.coverSizes[0] == nil)
        let originalURL = try #require(await container.downloadService.localCoverArtURL(forId: OriginalArtwork.storageID(id)))
        #expect(await container.downloadService.localCoverArtURL(forId: id) == originalURL)
        let stored = try Data(contentsOf: originalURL)
        #expect(stored == OriginalCoverProtocol.originalBytes())
        let source = try #require(CGImageSourceCreateWithData(stored as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2400)
        // Decoding stays bounded for memory; a full-size original remains on disk.
        let preferred = await cache.load(coverArtId: id, tier: .hero, allowNetwork: false)
        #expect(preferred?.size.width == 1200)
        #expect(await cache.downloadOriginalAndCacheAsHero(coverArtId: id))
        #expect(library.coverSizes.count == 1)
        await container.downloadService.removeCover(forId: OriginalArtwork.storageID(id))
        await container.downloadService.removeCover(forId: "\(id)@hero")
    }
}
