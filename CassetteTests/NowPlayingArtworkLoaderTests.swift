import Foundation
import MediaPlayer
import Testing
@testable import Cassette

nonisolated private final class ArtworkResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.path == "/unavailable" ? 503 : (request.value(forHTTPHeaderField: "X-Cover-Auth") == "test" ? 200 : 403)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==")!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Now Playing artwork network")
struct NowPlayingArtworkLoaderTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkResponseProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func currentTrackArtworkUsesAuthenticationAndCoalescesRequests() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let loader = ArtworkLoader(session: session)
        let url = URL(string: "https://artwork.test/cover")!
        async let first = loader.artwork(for: url, headers: ["X-Cover-Auth": "test"])
        async let second = loader.artwork(for: url, headers: ["X-Cover-Auth": "test"])
        let (a, b) = await (first, second)
        let artwork = try #require(a)
        #expect(artwork === b)
        let cached = await loader.artwork(for: url, headers: ["X-Cover-Auth": "test"])
        #expect(artwork === cached)
    }

    @Test func unsuccessfulResponseIsNotMistakenForArtwork() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        let loader = ArtworkLoader(session: session)
        #expect(await loader.artwork(for: URL(string: "https://artwork.test/unavailable")!, headers: ["X-Cover-Auth": "test"]) == nil)
        #expect(await loader.artwork(for: URL(string: "https://artwork.test/cover")!, headers: [:]) == nil)
        #expect(await loader.artwork(for: URL(string: "https://artwork.test/cover")!, headers: ["X-Cover-Auth": "test"]) != nil)
    }
    @Test func successfulArtworkDoesNotCrossCredentialBoundaries() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let loader = ArtworkLoader(session: session)
        let url = try #require(URL(string: "https://artwork.test/credential-change"))
        #expect(await loader.artwork(for: url, headers: ["X-Cover-Auth": "test"]) != nil)
        #expect(await loader.artwork(for: url, headers: [:]) == nil)
        #expect(await loader.artwork(for: url, headers: ["X-Cover-Auth": "test"]) != nil)
    }

}
