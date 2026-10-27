import Foundation
import SwiftUI
import SwiftData
import SwiftSonic
import Testing
@testable import Cassette

@Suite("Player experience regressions", .serialized)
@MainActor
struct PlayerExperienceRegressionTests {
    @Test func landscapeAnchorKeepsMeasuredLyricsAboveTheBottomInset() {
        for viewport: CGFloat in [140, 180, 220, 300] {
            for row: CGFloat in [44, 88, 130, 180] {
                let anchor = LyricScrollGeometry.anchor(viewportHeight: viewport, bottomInset: 8, rowHeight: row)
                let top = (viewport - row) * anchor
                if row <= viewport - 8 {
                    #expect(top >= 0)
                    #expect(top + row <= viewport - 8 + 0.01)
                } else {
                    #expect(anchor == 0) // oversized translations start at the top and remain scrollable
                }
            }
        }
    }

    @Test func pausedArtworkContractsInsideAnUnchangedSlot() throws {
        func bounds(playing: Bool) throws -> CGRect {
            let renderer = ImageRenderer(content: Color.red.frame(width: 200, height: 200)
                .modifier(PlayerArtworkPlaybackModifier(isPlaying: playing, reduceMotion: false))
                .frame(width: 240, height: 240))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == 240 && image.height == 240)
            var pixels = [UInt8](repeating: 0, count: 240 * 240 * 4)
            let context = try #require(CGContext(data: &pixels, width: 240, height: 240,
                bitsPerComponent: 8, bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 240))
            var result = CGRect.null
            for y in 0..<240 {
                for x in 0..<240 where pixels[(y * 240 + x) * 4] > 200 {
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            return result
        }
        let playing = try bounds(playing: true), paused = try bounds(playing: false)
        #expect(abs(playing.width - 200) <= 1)
        #expect(abs(paused.width - 146) <= 1)
        #expect(abs(playing.midX - paused.midX) <= 1)
        #expect(abs(playing.midY - paused.midY) <= 1)
    }

    @Test func explicitOriginalDownloadReusesRawTransferAndPreservesBytes() async throws {
        let defaults = UserDefaults.standard
        let formatKey = "cassette.streaming.download"
        let savedFormat = defaults.object(forKey: formatKey)
        let savedLossless = defaults.object(forKey: StreamingSettings.losslessAudioKey)
        defaults.set(CacheFormat.aac128.rawValue, forKey: formatKey)
        defaults.set(false, forKey: StreamingSettings.losslessAudioKey)
        defer {
            if let savedFormat { defaults.set(savedFormat, forKey: formatKey) }
            else { defaults.removeObject(forKey: formatKey) }
            if let savedLossless { defaults.set(savedLossless, forKey: StreamingSettings.losslessAudioKey) }
            else { defaults.removeObject(forKey: StreamingSettings.losslessAudioKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try ModelContainer.cassette(inMemory: true)
        let server = MockServerService()
        server.state.activeServer = ServerSnapshot(from: ServerConfig(displayName: "Fixture",
            baseURL: "https://example.invalid", username: "u"))
        server.credentials = ServerCredentials(password: "p", customHeaders: [:])
        let client = SwiftSonicClient(configuration: ServerConfiguration(serverURL: URL(string: "https://example.invalid")!,
            username: "u", password: "p"), retryPolicy: .none)
        server.musicClient = client
        let serverID = try #require(server.state.activeServer?.id)
        let identity = try server.state.requestIdentity(for: serverID)
        let song = try JSONDecoder().decode(Song.self, from: Data(
            #"{"id":"spatial","title":"Fixture","album":"Fixture (Dolby Atmos)","suffix":"mp3","duration":3}"#.utf8))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SilentMP3.mp3")
        let bytes = try Data(contentsOf: fixture)
        let source = root.appendingPathComponent("original.mp3")
        try bytes.write(to: source)
        let request = URLRequest(url: try #require(client.streamURL(id: song.id, format: "raw")))
        let coordinator = MediaTransferCoordinator()
        let key = MediaTransferKey(accountID: serverID, revision: identity.revision, songID: song.id, request: request)
        let cached = try CachedMediaTransfer(url: source, response: URLResponse(url: request.url!,
            mimeType: "audio/mpeg", expectedContentLength: bytes.count, textEncodingName: nil))
        try await coordinator.cache(key) { cached }
        let downloads = DownloadService(serverService: server, modelContainer: model, toastService: ToastService(),
            journal: BackgroundDownloadJournal(directory: root.appendingPathComponent("journal")),
            storageDirectory: root, transferCoordinator: coordinator)
        downloads.setOriginalArtworkLoader { _, _ in true }
        // A previously transcoded download must be upgraded, not accepted as an original.
        let old = root.appendingPathComponent("downloads/old.mp3")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: old)
        let context = ModelContext(model)
        context.insert(DownloadedTrack(songId: song.id, serverId: serverID, filePath: "old.mp3",
            fileSize: Int64(bytes.count), mimeType: "audio/mpeg", isOriginalAudio: false, title: song.title))
        try context.save()
        #expect(await downloads.downloadedOriginalURL(forSongId: song.id, serverId: serverID) == nil)
        try await downloads.downloadOriginal(song: song, serverId: serverID)
        let url = try #require(await downloads.downloadedOriginalURL(forSongId: song.id, serverId: serverID))
        #expect(try Data(contentsOf: url) == bytes)
        let record = try #require(ModelContext(model).fetch(FetchDescriptor<DownloadedTrack>()).first)
        #expect(record.isOriginalAudio == true)
        #expect(record.songId == song.id)
        // The MP3 fixture checks byte preservation/routing, not Atmos decoding.
    }
}
