import Foundation
import SwiftSonic

/// A transfer's identity and result outlive the Swift continuation and the app process.
/// Credentials and authenticated URLs belong to URLSession/Keychain, never this journal.
nonisolated final class BackgroundDownloadJournal: @unchecked Sendable {
    static let shared = BackgroundDownloadJournal(directory: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.cassette/download-transfers", isDirectory: true))

    struct Record: Codable, Sendable {
        let id: UUID
        let song: Song
        let serverID: UUID
        let format: CacheFormat
        let albumCoverArtID: String?
        let expectedOriginalSize: Int64?
        let originalContainer: String?
        var mimeType: String?
        var expectedContentLength: Int64?

        init(song: Song, serverID: UUID, format: CacheFormat, albumCoverArtID: String?,
             expectedOriginalSize: Int64?, originalContainer: String?) {
            id = UUID()
            self.song = song
            self.serverID = serverID
            self.format = format
            self.albumCoverArtID = albumCoverArtID
            self.expectedOriginalSize = expectedOriginalSize
            self.originalContainer = originalContainer
        }

        var response: URLResponse {
            URLResponse(url: URL(fileURLWithPath: "/download"), mimeType: mimeType,
                        expectedContentLength: Int(expectedContentLength ?? -1), textEncodingName: nil)
        }
    }

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) { self.directory = directory }

    func insert(_ record: Record) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directoryURL.setResourceValues(resources)
            try write(record)
        }
    }

    /// Move the system temporary file before returning from its delegate. Publish response
    /// metadata first: a crash before the move leaves an incomplete, safely ignored intent.
    func stage(id: UUID, file: URL, response: URLResponse) throws -> URL {
        try lock.withLock {
            var record = try read(id)
            if let expected = record.expectedOriginalSize, expected > 0 {
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                guard size == expected else { throw URLError(.badServerResponse) }
            }
            record.mimeType = response.mimeType
            record.expectedContentLength = response.expectedContentLength
            try write(record)
            let destination = payloadURL(id)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Duplicate completion after a relaunch must not replace an already staged file.
                return destination
            }
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
    }

    func completed() -> [Record] {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { file in
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      FileManager.default.fileExists(atPath: payloadURL(id).path) else { return nil }
                return try? read(id)
            }
        }
    }

    func payloadURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).audio") }

    func contains(_ id: UUID) -> Bool {
        lock.withLock { FileManager.default.fileExists(atPath: metadataURL(id).path) }
    }

    func remove(_ id: UUID) {
        lock.withLock { removeUnlocked(id) }
    }

    func remove(songID: String, serverID: UUID) {
        lock.withLock {
            for record in recordsUnlocked() where record.song.id == songID && record.serverID == serverID {
                removeUnlocked(record.id)
            }
        }
    }

    func removeAll() {
        lock.withLock { try? FileManager.default.removeItem(at: directory) }
    }

    private func recordsUnlocked() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            try? JSONDecoder().decode(Record.self, from: Data(contentsOf: $0))
        }
    }

    private func removeUnlocked(_ id: UUID) {
        // Invalidate the intent first so a racing delegate cannot stage cancelled content.
        try? FileManager.default.removeItem(at: metadataURL(id))
        try? FileManager.default.removeItem(at: payloadURL(id))
    }

    private func metadataURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func read(_ id: UUID) throws -> Record {
        try JSONDecoder().decode(Record.self, from: Data(contentsOf: metadataURL(id)))
    }
    private func write(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: metadataURL(record.id), options: .atomic)
    }
}

/// A network delegate can report thousands of chunks per second. UI progress needs at most
/// four updates per second, including an unconditional final update.
nonisolated struct DownloadProgressThrottle {
    private var lastEmission: TimeInterval?
    mutating func shouldEmit(now: TimeInterval, received: Int64, expected: Int64) -> Bool {
        if let lastEmission, now - lastEmission < 0.25, expected <= 0 || received < expected { return false }
        lastEmission = now
        return true
    }
}
