// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
@testable import Cassette

@Suite("CacheService — server isolation")
@MainActor
struct CacheServiceServerIsolationTests {
    @Test("file import preserves ownership, atomically replaces entries and rejects empty input")
    func fileImport() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CacheService(modelContainer: container, cacheDirectory: directory)
        let source = directory.appendingPathComponent("source.download")
        let server = UUID()
        let first = Data(repeating: 0x42, count: 1_048_576)
        try first.write(to: source)
        let destination = try await service.store(fileAt: source, forSongId: "song", serverId: server, mimeType: "audio/flac")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == first)
        #expect(await service.cachedURL(forSongId: "song", serverId: server) == destination)

        let replacement = Data(repeating: 0x55, count: 524_288)
        try replacement.write(to: source)
        _ = try await service.store(fileAt: source, forSongId: "song", serverId: server, mimeType: "audio/flac")
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(await service.trackCount == 1)
        #expect(await service.usedBytes == Int64(replacement.count))

        try Data().write(to: source)
        await #expect(throws: CocoaError.self) {
            _ = try await service.store(fileAt: source, forSongId: "song", serverId: server, mimeType: "audio/flac")
        }
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(await service.cachedURL(forSongId: "song", serverId: server) == destination)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".import-") })
    }

    @Test("the same song id resolves the cache entry for the requested server")
    func sameSongIdAcrossServers() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cassette-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = CacheService(modelContainer: container, cacheDirectory: directory)
        let firstServer = UUID()
        let secondServer = UUID()
        let songId = "shared-song-id"
        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)

        _ = try await service.store(
            data: firstData,
            forSongId: songId,
            serverId: firstServer,
            mimeType: "audio/mpeg"
        )
        _ = try await service.store(
            data: secondData,
            forSongId: songId,
            serverId: secondServer,
            mimeType: "audio/mpeg"
        )

        let firstURL = try #require(await service.cachedURL(forSongId: songId, serverId: firstServer))
        let secondURL = try #require(await service.cachedURL(forSongId: songId, serverId: secondServer))
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == firstData)
        #expect(try Data(contentsOf: secondURL) == secondData)
    }
}
