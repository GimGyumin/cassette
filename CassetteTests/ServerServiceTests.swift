// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
@testable import Cassette

// MARK: - Mock

@MainActor
final class MockKeychain: KeychainServiceProtocol {
    private var storage: [String: Data] = [:]
    private var failOnStore = false
    var retrieveOperation: ((String) async -> Void)?

    func setShouldFailOnStore(_ value: Bool) { failOnStore = value }

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        if failOnStore { throw CassetteError.keychainWriteFailed(-1) }
        storage[key] = try JSONEncoder().encode(value)
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        if let retrieveOperation { await retrieveOperation(key) }
        guard let data = storage[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func delete(forKey key: String) async throws {
        storage.removeValue(forKey: key)
    }
}

@MainActor
final class MockCacheService: CacheServiceProtocol {
    var cachedFileURL: URL?
    var usedBytes: Int64 {
        get async { 0 }
    }
    var trackCount: Int {
        get async { 0 }
    }
    var lyricsUsedBytes: Int64 {
        get async { 0 }
    }
    var lyricsCount: Int {
        get async { 0 }
    }
    func cachedURL(forSongId songId: String, serverId: UUID) async -> URL? { cachedFileURL }
    func touch(songId: String, serverId: UUID) async {}
    func store(data: Data, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        struct MockError: Error {}; throw MockError()
    }
    func store(fileAt sourceURL: URL, forSongId songId: String, serverId: UUID, mimeType: String) async throws -> URL {
        struct MockError: Error {}; throw MockError()
    }
    func setMaxBytes(_ value: Int64) async {}
    func invalidate(songId: String, serverId: UUID) async {}
    func clearAll() async {}
    func clearAudioTracksOnly() async {}
    func clearLyricsCache() async {}
    func clearAllForServer(_ serverId: UUID) async {}
}

// MARK: - Suite

@Suite("ServerService")
@MainActor
struct ServerServiceTests {

    private func makeService(keychain: MockKeychain? = nil) throws -> (ServerService, ServerState) {
        // Default argument expressions are nonisolated — resolve the @MainActor
        // mock inside the MainActor method body instead.
        let keychain = keychain ?? MockKeychain()
        let container = try ModelContainer.cassette(inMemory: true)
        let state = ServerState()
        let service = ServerService(state: state, keychain: keychain, modelContainer: container, cacheService: MockCacheService())
        return (service, state)
    }

    // MARK: addServer

    @Test func quickConnectVerificationStateTracksCredentials() async throws {
        let keychain = MockKeychain()
        let (service, state) = try makeService(keychain: keychain)
        try await service.addServer(displayName: "Music", baseURL: "https://music.example.com",
                                    username: "listener", password: "", customHeaders: [:])
        let id = try #require(state.activeServer?.id)
        try await keychain.store(ServerCredentials(password: "", customHeaders: [:], jellyfinAccessToken: "quick-connect-token"),
                                 forKey: ServerCredentials.keychainKey(for: id))
        await service.refreshCredentialAvailability()
        #expect(state.needsSubsonicVerification)
        #expect(!state.needsCredentialReentry)
        try await service.updateServer(id: id, displayName: "Music", baseURL: "https://music.example.com",
                                       username: "listener", password: "verified-password", customHeaders: [:])
        #expect(!state.needsSubsonicVerification)
        let credentials = try await service.activeCredentials()
        #expect(credentials.password == "verified-password")
        #expect(credentials.jellyfinAccessToken == nil)
        await service.loadPersistedState()
        #expect(!state.needsSubsonicVerification)
    }

    @Test func addServer_firstServer_becomesActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "My Server", baseURL: "https://music.example.com",
            username: "admin", password: "secret", customHeaders: [:]
        )

        #expect(state.servers.count == 1)
        #expect(state.activeServer?.username == "admin")
        #expect(state.activeServer?.displayName == "My Server")
    }

    @Test func addServer_secondServer_doesNotBecomeActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S1", baseURL: "https://s1.example.com",
            username: "user1", password: "pass", customHeaders: [:]
        )
        try await service.addServer(
            displayName: "S2", baseURL: "https://s2.example.com",
            username: "user2", password: "pass", customHeaders: [:]
        )

        #expect(state.servers.count == 2)
        #expect(state.activeServer?.username == "user1")
    }

    @Test func addServer_afterActiveServerRemoved_activatesAndPersistsNewServer() async throws {
        let (service, state) = try makeService()
        try await service.addServer(displayName: "Active", baseURL: "https://first.example.com",
                                    username: "first", password: "secret", customHeaders: [:])
        let firstID = try #require(state.activeServer?.id)
        try await service.addServer(displayName: "Inactive", baseURL: "https://second.example.com",
                                    username: "second", password: "secret", customHeaders: [:])
        try await service.removeServer(id: firstID)
        #expect(state.activeServer == nil)
        #expect(state.servers.count == 1)

        try await service.addServer(displayName: "New login", baseURL: "https://third.example.com",
                                    username: "third", password: "secret", customHeaders: [:])
        let newID = try #require(state.activeServer?.id)
        #expect(state.activeServer?.username == "third")
        #expect(state.servers.count == 2)
        await service.loadPersistedState()
        #expect(state.activeServer?.id == newID)
    }

    @Test func addServer_invalidHeaderName_throwsInvalidHeaderName() async throws {
        let (service, _) = try makeService()

        await #expect(throws: CassetteError.self) {
            try await service.addServer(
                displayName: "S", baseURL: "https://s.example.com",
                username: "u", password: "p",
                customHeaders: ["Bad Header": "value"]
            )
        }
    }

    @Test func addServer_keychainFailure_stateUnchanged() async throws {
        let keychain = MockKeychain()
        keychain.setShouldFailOnStore(true)
        let (service, state) = try makeService(keychain: keychain)

        try? await service.addServer(
            displayName: "S", baseURL: "https://s.example.com",
            username: "u", password: "p", customHeaders: [:]
        )

        #expect(state.servers.isEmpty)
        #expect(state.activeServer == nil)
    }

    // MARK: removeServer

    @Test func removeServer_removesFromStateAndClearsActive() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S", baseURL: "https://s.example.com",
            username: "u", password: "p", customHeaders: [:]
        )
        let id = try #require(state.servers.first).id
        try await service.removeServer(id: id)

        #expect(state.servers.isEmpty)
        #expect(state.activeServer == nil)
        #expect(state.isConnected == false)
    }

    @Test func removeServer_unknownId_throwsServerNotFound() async throws {
        let (service, _) = try makeService()

        await #expect(throws: CassetteError.self) {
            try await service.removeServer(id: UUID())
        }
    }

    // MARK: setActiveServer

    @Test func setActiveServer_switchesActiveServer() async throws {
        let (service, state) = try makeService()

        try await service.addServer(
            displayName: "S1", baseURL: "https://s1.example.com",
            username: "user1", password: "pass", customHeaders: [:]
        )
        try await service.addServer(
            displayName: "S2", baseURL: "https://s2.example.com",
            username: "user2", password: "pass", customHeaders: [:]
        )

        let s2Id = try #require(state.servers.first(where: { $0.username == "user2" })).id
        try await service.setActiveServer(id: s2Id)

        #expect(state.activeServer?.username == "user2")
        #expect(state.isConnected == false)
    }

    @Test func setActiveServer_unknownId_throwsServerNotFound() async throws {
        let (service, _) = try makeService()

        await #expect(throws: CassetteError.self) {
            try await service.setActiveServer(id: UUID())
        }
    }

    // MARK: loadPersistedState

    @Test func loadPersistedState_restoresServersAndActiveServer() async throws {
        let keychain = MockKeychain()
        let container = try ModelContainer.cassette(inMemory: true)

        let state1 = ServerState()
        let service1 = ServerService(state: state1, keychain: keychain, modelContainer: container, cacheService: MockCacheService())
        try await service1.addServer(
            displayName: "Persisted", baseURL: "https://s.example.com",
            username: "user", password: "pass", customHeaders: [:]
        )

        // Simulate app restart: new service with the same container
        let state2 = ServerState()
        let service2 = ServerService(state: state2, keychain: keychain, modelContainer: container, cacheService: MockCacheService())

        #expect(state2.servers.isEmpty)
        await service2.loadPersistedState()

        #expect(state2.servers.count == 1)
        #expect(state2.activeServer?.username == "user")
        #expect(state2.isLoadingPersistedState == false)
    }
}
