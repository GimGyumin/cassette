import Foundation
import Network
import Testing
import SwiftSonic
import AudioStreaming
@testable import Cassette

/// Real loopback HTTP responses and AVPlayer decoding, without credentials or external servers.
/// Offset responses intentionally ignore Range, matching an encoder with a growing output file.
nonisolated private final class SeekHTTPFixtureServer: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        var query: [String: String] {
            Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name.lowercased(), $0) } }, uniquingKeysWith: { _, new in new })
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cassette.test.seek-http")
    private let lock = NSLock()
    private var port: UInt16?
    private var startupError: NWError?
    private var recorded: [Request] = []
    private var connections: [UUID: NWConnection] = [:]
    private let packets: [Data]
    private let samplesPerPacket: Double
    private let codec: String
    private let delay: Double
    private let advertisesOffset: Bool
    private let rejectsStreams: Bool
    private let mediaDuration: Double

    var requests: [Request] { lock.withLock { recorded } }

    init(codec: String, delay: Double = 0, advertisesOffset: Bool = true, rejectsStreams: Bool = false,
         mediaDuration: Double = 180) throws {
        self.codec = codec
        self.delay = delay
        self.advertisesOffset = advertisesOffset
        self.rejectsStreams = rejectsStreams
        self.mediaDuration = mediaDuration
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(codec == "aac" ? "Fixtures/SilentAAC.adts" : "Fixtures/SilentMP3.mp3")
        let bytes = [UInt8](try Data(contentsOf: fixture))
        var frames: [Data] = []
        var cursor = 0
        while cursor + 7 < bytes.count {
            let length: Int
            if codec == "aac" {
                guard bytes[cursor] == 0xff, bytes[cursor + 1] & 0xf0 == 0xf0 else { cursor += 1; continue }
                length = Int(bytes[cursor + 3] & 3) << 11 | Int(bytes[cursor + 4]) << 3 | Int(bytes[cursor + 5] >> 5)
            } else {
                guard bytes[cursor] == 0xff, bytes[cursor + 1] & 0xfe == 0xfa else { cursor += 1; continue }
                let rates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
                length = 144_000 * rates[Int(bytes[cursor + 2] >> 4)] / 44_100 + Int(bytes[cursor + 2] >> 1 & 1)
            }
            guard length > 7, cursor + length <= bytes.count else { break }
            frames.append(Data(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        guard !frames.isEmpty else { throw URLError(.cannotDecodeContentData) }
        packets = frames
        samplesPerPacket = codec == "aac" ? 1_024 : 1_152
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.withLock {
                if case .ready = state { self.port = self.listener.port?.rawValue }
                if case .failed(let error) = state { self.startupError = error }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func baseURL() async throws -> URL {
        for _ in 0..<100 {
            let state = lock.withLock { (port, startupError) }
            if let error = state.1 { throw error }
            if let port = state.0, let url = URL(string: "http://127.0.0.1:\(port)/proxy") { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    func stop() {
        listener.cancel()
        let active = lock.withLock { let items = Array(connections.values); connections.removeAll(); return items }
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) } }
        }
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, text: text)
            } else if !ended, error == nil, bytes.count < 65_536 {
                self.receive(connection, accumulated: bytes)
            } else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, text: String) {
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2, let url = URL(string: "http://127.0.0.1" + first[1]) else { connection.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(url: url, headers: headers)
        lock.withLock { recorded.append(request) }
        let body: Data
        let mime: String
        var status = 200
        if ["ping", "getOpenSubsonicExtensions"].contains(url.deletingPathExtension().lastPathComponent) {
            let extensions: [[String: Any]] = advertisesOffset ? [["name": "transcodeOffset", "versions": [1]]] : []
            body = (try? JSONSerialization.data(withJSONObject: ["subsonic-response": [
                "status": "ok", "version": "1.16.1", "type": "navidrome", "openSubsonic": true,
                "openSubsonicExtensions": extensions
            ]])) ?? Data()
            mime = "application/json"
        } else if rejectsStreams {
            status = 503
            body = Data("unavailable".utf8)
            mime = "text/plain"
        } else {
            let offset = Double(request.query["timeoffset"] ?? "0") ?? 0
            let ticks = Double(request.query["starttimeticks"] ?? "0") ?? 0
            let time = max(offset, ticks / 10_000_000)
            let firstPacket = Int(time * 44_100 / samplesPerPacket)
            let count = max(1, Int(ceil((mediaDuration - time) * 44_100 / samplesPerPacket)))
            var result = Data()
            for index in firstPacket..<(firstPacket + count) { result.append(packets[index % packets.count]) }
            body = result
            mime = codec == "aac" ? "audio/aac" : "audio/mpeg"
        }
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        if first[0] != "HEAD" { response.append(body) }
        let responseBytes = response
        queue.asyncAfter(deadline: .now() + (mime == "application/json" ? 0 : delay)) {
            connection.send(content: responseBytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Time-offset HTTP × AVPlayer", .serialized)
@MainActor
struct TranscodeHTTPSeekTests {
    @Test func promptStartupIgnoresReplacedItemsAndRespectsPauseIntent() async throws {
        let http = try SeekHTTPFixtureServer(codec: "aac", delay: 0.15, mediaDuration: 10)
        defer { http.stop() }
        let base = try await http.baseURL()
        let engine = AVPlayerPlaybackEngine()
        defer { engine.stop() }
        engine.volume = 0
        for generation in 1...8 {
            let url = try #require(URL(string: base.absoluteString + "/stream.aac?id=\(generation)"))
            engine.start(url: url, headers: [:], generation: UInt64(generation),
                         paused: generation == 8, reusingPlayer: true, promptStartupBuffer: 1)
        }
        try await waitUntil { engine.isReadyForPlayback }
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state == .paused)
        #expect(engine.progress < 0.1)
        engine.resume()
        try await waitUntil { engine.state == .playing && engine.progress > 0.1 }
        engine.pause()
        try await Task.sleep(for: .milliseconds(100))
        let pausedPosition = engine.progress
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state == .paused)
        #expect(abs(engine.progress - pausedPosition) < 0.1)
        engine.resume()
        try await waitUntil { engine.state == .playing && engine.progress > pausedPosition + 0.1 }
    }

    @Test(arguments: ["aac", "mp3"])
    func progressiveHTTPPreparesTheNextStreamBeforeEOF(codec: String) async throws {
        let http = try SeekHTTPFixtureServer(codec: codec, delay: 0.2, mediaDuration: 3)
        defer { http.stop() }
        let base = try await http.baseURL()
        let first = try #require(URL(string: base.absoluteString + "/stream.\(codec)?id=first"))
        let next = try #require(URL(string: base.absoluteString + "/stream.\(codec)?id=next"))
        let engine = AVPlayerPlaybackEngine()
        defer { engine.stop() }
        engine.volume = 0
        engine.start(url: first, headers: ["X-Startup-Test": "preserved"], generation: 1, promptStartupBuffer: 1)
        let start = ContinuousClock.now
        try await waitUntil { engine.state == .playing && engine.progress > 0.1 }
        #expect(start.duration(to: .now) < .seconds(2), "A small, fully available HTTP stream must start promptly")
        #expect(engine.prepareNext(url: next, headers: ["X-Startup-Test": "preserved"]))
        try await waitUntil { http.requests.contains { $0.query["id"] == "next" } }
        #expect(engine.progress < 2.5, "The next HTTP request must start before the first song ends")
        var advanced = false
        try await waitUntil {
            advanced = engine.consumeQueuedTransition() || advanced
            return advanced
        }
        try await waitUntil { engine.state == .playing && engine.progress > 0.1 }
        #expect(!engine.hasQueuedItem)
        for request in http.requests { #expect(request.headers["x-startup-test"] == "preserved") }
    }

    @Test(arguments: ["navidrome", "jellyfin"], ["aac", "mp3"])
    func realHTTPSeekUsesTheLastOffsetAndKeepsTheAbsoluteClock(serverKind: String, codec: String) async throws {
        let http = try SeekHTTPFixtureServer(codec: codec, delay: 0.15)
        defer { http.stop() }
        let baseURL = try await http.baseURL()
        let container = try AppContainer(inMemory: true, engine: FakePlaybackEngine())
        let service = try #require(container.playerService as? PlayerService)
        defer { Task { await service.stop() } }
        let source: MediaSource
        if serverKind == "navidrome" {
            let client = SwiftSonicClient(configuration: ServerConfiguration(serverURL: baseURL, username: "test", password: "password"))
            let caps = try await client.loadCapabilities()
            #expect(caps.supports("transcodeOffset"))
            let url = try #require(client.streamURL(id: "flac-track", maxBitRate: 128, format: codec))
            source = .stream(url, customHeaders: ["X-Seek-Test": "preserved"], supportsTranscodeOffset: caps.supports("transcodeOffset"))
        } else {
            let client = try JellyfinClient(serverBaseURL: baseURL, accessToken: "test-token", deviceID: "test-device")
            let url = try #require(client.progressiveAudioURL(itemID: "flac-track", container: codec, audioCodec: codec,
                audioBitRate: 128_000, mediaSourceID: "source", playSessionID: "session"))
            source = .stream(url, customHeaders: ["X-Seek-Test": "preserved"], jellyfin: .init(
                itemID: "flac-track", mediaSourceID: "source", playSessionID: "session", playMethod: .transcode, route: .universal))
        }
        let track = DisplayableSong(id: "flac-track", title: "FLAC", duration: 180, audioFormat: "flac",
            bitRate: 1_411, bitDepth: 16, samplingRate: 44_100, channelCount: 2)
        container.playerState.currentTrack = track
        container.playerState.queue = [track]
        container.playerState.duration = 180
        container.playerState.playbackState = .loading
        await service.installHTTPSeekSource(source)
        let nowPlaying = SeekNowPlayingRecorder()
        await service.setNowPlayingService(nowPlaying)
        // Rapid releases during cold acquisition: one final server offset, not one per sample.
        let first = Task { await service.seek(to: 40) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { await service.seek(to: 80) }
        try await Task.sleep(for: .milliseconds(20))
        await service.seek(to: 162)
        await first.value
        await second.value
        let pendingSnapshots = nowPlaying.snapshots
        #expect(pendingSnapshots.last?.position == 162)
        #expect(pendingSnapshots.last?.duration == 180)
        #expect(pendingSnapshots.last?.playbackRate == 0)
        try await waitUntil { container.playerState.position > 162.05 && container.playerState.playbackState == .playing }
        let player = try #require(service.systemEngine.playerIdentity)
        #expect(container.playerState.duration == 180)
        #expect(container.playerState.currentIndex == 0)
        try await waitUntil { container.playerState.isDeliveringTranscodedAudio }
        let audio = http.requests.filter { !["ping", "getOpenSubsonicExtensions"].contains($0.url.deletingPathExtension().lastPathComponent) }
        #expect(!audio.isEmpty)
        for request in audio {
            #expect(request.headers["x-seek-test"] == "preserved")
            if serverKind == "navidrome" {
                #expect(request.query["timeoffset"] == "162")
                #expect(request.query["format"] == codec)
                #expect(request.query["maxbitrate"] == "128")
                #expect(request.query["t"] != nil && request.query["s"] != nil)
            } else {
                #expect(request.query["starttimeticks"] == "1620000000")
                #expect(request.query["audiocodec"] == codec)
                #expect(request.query["audiobitrate"] == "128000")
                #expect(request.query["deviceid"] == "test-device")
                #expect(request.query["mediasourceid"] == "source" && request.query["playsessionid"] == "session")
                #expect(request.query["api_key"] == "test-token")
            }
        }
        await service.pause()
        await service.seek(to: 10)
        try await waitUntil { service.systemEngine.isReadyForPlayback && !service.systemEngine.isSeeking }
        #expect(container.playerState.playbackState == .paused)
        #expect(abs(await service.engineProgress() - 10) < 0.1)
        #expect(service.systemEngine.playerIdentity == player)
        await service.seek(to: 179.8)
        try await waitUntil { service.systemEngine.isReadyForPlayback && !service.systemEngine.isSeeking }
        #expect(container.playerState.playbackState == .paused)
        await service.seek(to: 0)
        try await waitUntil { service.systemEngine.isReadyForPlayback && !service.systemEngine.isSeeking }
        #expect(abs(await service.engineProgress()) < 0.1)
        await service.resume()
        try await waitUntil { container.playerState.position > 0.05 && container.playerState.playbackState == .playing }
        #expect(container.playerState.duration == 180)
        #expect(container.playerState.currentIndex == 0)
        #expect(service.systemEngine.playerIdentity == player)
        try await waitUntil { service.systemEngine.actualCodec == codec.uppercased() }
        #expect(await service.playbackDetails()?.actualCodec == codec.uppercased())
        await service.stop()
    }

    @Test func missingOffsetCapabilityDoesNotBecomeAssumedSupport() async throws {
        let http = try SeekHTTPFixtureServer(codec: "aac", advertisesOffset: false)
        defer { http.stop() }
        let client = SwiftSonicClient(configuration: ServerConfiguration(serverURL: try await http.baseURL(), username: "u", password: "p"))
        let caps = try await client.loadCapabilities()
        #expect(!caps.supports("transcodeOffset"))
        let source = MediaSource.stream(try #require(client.streamURL(id: "track", format: "aac")), customHeaders: [:],
            supportsTranscodeOffset: caps.supports("transcodeOffset"))
        #expect(source.transcodeRequest(at: 90) == nil)
    }

    private func waitUntil(line: Int = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting at line \(line)")
    }
}

private extension PlayerService {
    func installHTTPSeekSource(_ source: MediaSource) { currentSource = source; gaplessEnabled = false }
}

@MainActor
private final class SeekNowPlayingRecorder: NowPlayingServiceProtocol {
    var snapshots: [NowPlayingSnapshot] = []
    func start() {}
    func stop() {}
    func clearArtworkCache() {}
    func update(with snapshot: NowPlayingSnapshot) { snapshots.append(snapshot) }
    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) {}
    func setISRC(_ isrc: String) {}
    func setPlaybackRate(_ rate: Float) {}
    func clearISRC() {}
    func publishTrackChange(_ snapshot: NowPlayingSnapshot) { snapshots.append(snapshot) }
    func reassertRemoteCommands() {}
}
