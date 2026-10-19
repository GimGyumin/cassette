import Foundation
import SwiftData
import SwiftSonic
import Synchronization
import Testing
@testable import Cassette

@Suite("Log audit regression", .serialized)
struct LogAuditRegressionTests {
    @Test func httpFailurePreservesStatusAndRetryAfterWithoutCredentials() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://user:secret@example.invalid/rest/stream.view?t=token")!,
            statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        let error = HTTPTransferFailure(response: response, stage: "audio response", now: now)
        #expect(error.statusCode == 429)
        #expect(error.retryAfter == 120)
        #expect(error.endpoint == "stream.view")
        for secret in ["user", "secret", "token", "?"] { #expect(!error.description.contains(secret)) }
        #expect(PlaybackFailure.classify(CassetteError.downloadFailed(songId: "song", underlying: error)).code == 429)
        #expect(HTTPTransferFailure.retryDelay("Thu, 01 Jan 1970 00:20:00 GMT", now: now) == 200)
        #expect(HTTPTransferFailure.retryDelay("nan", now: now) == nil)
    }

    @Test func automaticRetryHonorsServerDelayAndHasAnAttemptLimit() throws {
        var policy = AutomaticMediaRetryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.invalid/stream")!,
            statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "600"]))
        let error = CassetteError.downloadFailed(songId: "song", underlying: HTTPTransferFailure(response: response, stage: "audio"))
        let key = "account-revision-song-quality"
        policy.failed(key, error: error, now: now)
        #expect(!policy.permits(key, now: now.addingTimeInterval(599)))
        #expect(policy.permits(key, now: now.addingTimeInterval(600)))
        policy.failed(key, error: error, now: now.addingTimeInterval(600))
        policy.failed(key, error: error, now: now.addingTimeInterval(1200))
        #expect(!policy.permits(key, now: now.addingTimeInterval(86_400)))
        #expect(policy.permits("new-account-revision", now: now))
        policy.succeeded(key)
        #expect(policy.permits(key, now: now))
        policy.failed(key, error: SwiftSonicError.network(URLError(.cancelled)), now: now)
        #expect(policy.permits(key, now: now))
    }

    @Test(arguments: [48_000, 88_200, 96_000, 192_000])
    func losslessAvoidsFixed44100Decoder(sampleRate: Int) {
        let lossless = DisplayableSong(id: "flac", title: "Native", audioFormat: "flac",
            bitDepth: 24, samplingRate: sampleRate, channelCount: 2)
        #expect(AudioQualityClassifier.requiresNativeSampleRate(lossless))
        #expect(AudioQualityClassifier.requiresSystemPlayer(lossless))
        let lossy = DisplayableSong(id: "aac", title: "Lossy", audioFormat: "aac",
            samplingRate: sampleRate, channelCount: 2)
        #expect(!AudioQualityClassifier.requiresNativeSampleRate(lossy))
    }

    @Test @MainActor func progressTimerDoesNotRepublishSystemMetadataButEventsStillDo() async throws {
        let f = try AuditPlaybackFixture()
        let spy = AuditNowPlayingSpy()
        await f.player.setNowPlayingService(spy)
        await f.player.suppressAuditServerCapabilityProbe()
        for second in stride(from: 0, through: 120, by: 5) {
            await f.player.periodicNowPlayingPush(elapsed: Double(second))
        }
        #expect(spy.positions == 0)
        #expect(spy.updates.isEmpty)
        await f.player.pushPositionSnapshot(rate: 0)
        await f.player.pushPositionSnapshot(rate: 1)
        #expect(spy.updates.map(\.playbackRate) == [0, 1])
        await f.player.stop()
    }

    @Test @MainActor func wrappedLyricsCancellationPropagatesAsCancellation() async throws {
        let key = LyricsSourcePreference.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(LyricsSourcePreference.embedded.rawValue, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let server = MockLyricsServerService()
        server.lyricsClient = SwiftSonicClient(configuration: ServerConfiguration(
            serverURL: URL(string: "https://lyrics.invalid")!, username: "test", password: "test"),
            transport: CancelledLyricsTransport(), retryPolicy: .none)
        let model = try ModelContainer(for: Schema([CachedLyrics.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = LyricsService(serverService: server, modelContainer: model)
        do {
            _ = try await service.fetchLyrics(forSongId: "cancelled", serverId: UUID())
            Issue.record("Cancelled lyrics unexpectedly succeeded")
        } catch { #expect(error is CancellationError) }
    }

    @Test func musicBrainzRetriesHttpFailuresThenCachesTheResult() async throws {
        AuditMusicProtocol.record.withLock { $0 = .init(statuses: [429, 503, 200]) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditMusicProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = MusicBrainzCatalogService(session: session, requestInterval: 0.01, retryBaseDelay: 0.01)
        #expect(await service.catalogISRC(title: "Song", artist: "Artist", album: "Album") == "TEST123")
        #expect(await service.catalogISRC(title: "Song", artist: "Artist", album: "Album") == "TEST123")
        let times = AuditMusicProtocol.record.withLock { $0.times }
        #expect(times.count == 3)
        if times.count == 3 { #expect(times[1].timeIntervalSince(times[0]) >= 0.05) }
    }

    @Test func musicBrainzDoesNotRetryAuthorizationOrFallbackQueriesAfterFailure() async throws {
        AuditMusicProtocol.record.withLock { $0 = .init(statuses: [403]) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditMusicProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = MusicBrainzCatalogService(session: session, requestInterval: 0.01, retryBaseDelay: 0.01)
        #expect(await service.catalogISRC(title: "Song", artist: "Artist", album: "Album") == nil)
        #expect(await service.catalogISRC(title: "Song", artist: "Artist", album: "Album") == nil)
        #expect(AuditMusicProtocol.record.withLock { $0.times.count } == 1)
    }
}

private actor CancelledLyricsTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cancelled)
    }
}

@MainActor private final class AuditNowPlayingSpy: NowPlayingServiceProtocol {
    var positions = 0
    var updates: [NowPlayingSnapshot] = []
    func start() async {}
    func stop() async {}
    func clearArtworkCache() async {}
    func update(with snapshot: NowPlayingSnapshot) async { updates.append(snapshot) }
    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async { positions += 1 }
    func setISRC(_ isrc: String) async {}
    func setPlaybackRate(_ rate: Float) async {}
    func clearISRC() async {}
    func publishTrackChange(_ snapshot: NowPlayingSnapshot) async { updates.append(snapshot) }
    func reassertRemoteCommands() async {}
}

private extension PlayerService {
    func suppressAuditServerCapabilityProbe() { playbackReportSupported = false }
}

nonisolated private final class AuditMusicProtocol: URLProtocol, @unchecked Sendable {
    struct Record { var statuses: [Int]; var times: [Date] = [] }
    static let record = Mutex(Record(statuses: []))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.record.withLock { value in
            value.times.append(Date())
            return value.statuses.isEmpty ? 200 : value.statuses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Retry-After": "0.05"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"recordings":[{"title":"Song","isrcs":["TEST123"]}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
