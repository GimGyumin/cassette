import Foundation
import CoreGraphics
import ImageIO
import Network
import Synchronization
import Testing
@testable import Cassette

/// A real local HTTP server exercises URLSession download delegates and file installation.
/// No simulator or background-execution entitlement is involved in these transport tests.
nonisolated private final class ArtworkHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    let requests = Mutex(0)
    private let queue = DispatchQueue(label: "cassette.test.artwork-http")
    private let payload: Data
    private let initialFailures: Int

    init(payload: Data, initialFailures: Int = 0) throws {
        self.payload = payload
        self.initialFailures = initialFailures
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, data != nil else { connection.cancel(); return }
                let number = self.requests.withLock { $0 += 1; return $0 }
                self.queue.asyncAfter(deadline: .now() + 0.15) {
                    let status = number <= self.initialFailures ? "503 Service Unavailable" : "200 OK"
                    var response = Data("HTTP/1.1 \(status)\r\nContent-Type: image/png\r\nContent-Length: \(self.payload.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(self.payload)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}

@Suite("Artwork queue handoff") @MainActor
struct BackgroundArtworkQueueTests {
    @Test func retryPolicyRejectsCancellationAndPermanentResponses() {
        let url = URL(string: "https://example.invalid")!
        #expect(CassetteBackgroundDownloads.shouldRetryArtwork(error: URLError(.timedOut), response: nil))
        #expect(!CassetteBackgroundDownloads.shouldRetryArtwork(error: URLError(.cancelled), response: nil))
        for code in [401, 403, 404] {
            #expect(!CassetteBackgroundDownloads.shouldRetryArtwork(error: nil,
                response: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: [1, 9])
    func temporaryServerFailureRetriesWithTheSameObserverAndStopsAtTheLimit(failures: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(encoder))
        let server = try ArtworkHTTPFixture(payload: png as Data, initialFailures: failures)
        let base = try await server.start()
        defer { server.listener.cancel() }
        let transfers = CassetteBackgroundDownloads(identifier: CassetteBackgroundDownloads.artworkSessionIdentifier,
            configuration: .ephemeral)
        let destination = root.appendingPathComponent("retry@original-v1")
        do {
            _ = try await transfers.download(request: URLRequest(url: base), clientKey: "retry", persistentArtworkURL: destination)
            #expect(failures == 1)
            #expect(CassetteBackgroundDownloads.isValidArtwork(at: destination))
        } catch {
            #expect(failures == 9)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(server.requests.withLock { $0 } == (failures == 1 ? 2 : 3))
        await transfers.cancelAll()
    }

    @Test func wholeBatchFinishesWithoutPerFileAwaitersAndObserversDoNotRedownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let png = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(encoder))
        let server = try ArtworkHTTPFixture(payload: png as Data)
        let baseURL = try await server.start()
        defer { server.listener.cancel() }
        let transfers = CassetteBackgroundDownloads(identifier: CassetteBackgroundDownloads.artworkSessionIdentifier,
            configuration: .ephemeral)
        let files = (0..<4).map { root.appendingPathComponent("account-\($0)@original-v1") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid cached image".utf8).write(to: files[0])
        for (index, file) in files.enumerated() {
            transfers.enqueueArtwork(request: URLRequest(url: baseURL.appendingPathComponent("\(index)")), destination: file)
        }
        await transfers.restoreArtworkTasks()
        // A second inventory scan must join the same daemon jobs.
        for (index, file) in files.enumerated() {
            transfers.enqueueArtwork(request: URLRequest(url: baseURL.appendingPathComponent("\(index)")), destination: file)
        }
        let observer = Task {
            try await transfers.download(request: URLRequest(url: baseURL.appendingPathComponent("0")),
                clientKey: files[0].lastPathComponent, persistentArtworkURL: files[0])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !files.allSatisfy({ CassetteBackgroundDownloads.isValidArtwork(at: $0) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = files.allSatisfy { CassetteBackgroundDownloads.isValidArtwork(at: $0) }
        if !completed { observer.cancel(); await transfers.cancelAll() }
        try #require(completed)
        #expect(try await observer.value.0 == files[0])
        #expect(server.requests.withLock { $0 } == 4)
        for file in files {
            #expect(CassetteBackgroundDownloads.isValidArtwork(at: file))
            #expect(try Data(contentsOf: file) == png as Data)
        }
        let identity = try #require(ArtworkContentStore.fileIdentity(files[0]))
        #expect(files.allSatisfy { ArtworkContentStore.fileIdentity($0) == identity })
        // Attaching after didFinish/didComplete must complete from disk, never hang or fetch twice.
        _ = try await transfers.download(request: URLRequest(url: baseURL.appendingPathComponent("0")),
            clientKey: files[0].lastPathComponent, persistentArtworkURL: files[0])
        #expect(server.requests.withLock { $0 } == 4)
        await transfers.cancelAll()
    }
}
