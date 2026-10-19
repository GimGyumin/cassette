// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

nonisolated struct ServerRequestIdentity: Sendable, Equatable {
    let serverID: UUID
    let revision: UInt64
}

nonisolated struct ServerRequestContext: Sendable {
    let identity: ServerRequestIdentity
    let client: SwiftSonicClient
    let credentials: ServerCredentials
}

protocol ServerServiceProtocol: AnyObject, Sendable {
    /// Observable UI state (MainActor-isolated). Access directly from SwiftUI views.
    var state: ServerState { get }

    func addServer(
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    /// Adds a Navidrome server authenticated by the JWT returned from Jellyfin Quick Connect.
    /// The token stays in Keychain and is sent through Navidrome's supported `jwt` parameter.
    func addServerWithJellyfinToken(
        displayName: String,
        baseURL: String,
        username: String,
        jellyfinAccessToken: String,
        customHeaders: [String: String]
    ) async throws

    /// Atomically removes server from SwiftData and Keychain.
    /// Performs best-effort rollback if one step fails after the other succeeds.
    func removeServer(id: UUID) async throws

    func setActiveServer(id: UUID) async throws

    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws

    /// Updates all editable fields of a persisted server in SwiftData and Keychain.
    /// Tests connectivity before writing; throws `ConnectionTestError` on failure.
    func updateServer(
        id: UUID,
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    /// Pings the active server via SwiftSonic. Throws if no active server or ping fails.
    func testConnection() async throws

    /// Tests connectivity to the given parameters without persisting anything.
    /// Runs ping then getUser for full credential validation.
    /// Throws `ConnectionTestError` for differentiated UI error handling.
    func testConnection(
        url: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws

    /// Returns a SwiftSonicClient configured with CustomHeadersTransport for the active server.
    /// Callers must NOT cache this client — always request a fresh one to pick up config changes.
    func makeSwiftSonicClient() async throws -> SwiftSonicClient

    /// A dedicated client for slow, sequential server-side lyrics generation.
    func makeLyricsGenerationClient() async throws -> SwiftSonicClient

    /// Returns the stored credentials for the active server.
    /// Used by MediaResolver and DownloadService to inject headers into AVPlayer / URLSession.
    func activeCredentials() async throws -> ServerCredentials

    /// One account owns the URL builder and headers throughout resolution.
    func requestContext(serverID: UUID) async throws -> ServerRequestContext

    /// Restores servers and activeServer from SwiftData + Keychain on app launch.
    /// Sets state.isLoadingPersistedState = false when complete (even on failure).
    func loadPersistedState() async

    /// Warms Keychain + client construction so the first Home fetch isn't blocked on it.
    func preWarmClient() async
}


extension ServerServiceProtocol {
    func requestContext(serverID: UUID) async throws -> ServerRequestContext {
        let identity = try await MainActor.run { try state.requestIdentity(for: serverID) }
        async let client = makeSwiftSonicClient()
        async let credentials = activeCredentials()
        let context = try await ServerRequestContext(identity: identity, client: client, credentials: credentials)
        try Task.checkCancellation()
        guard await MainActor.run(body: { state.requestIsCurrent(identity) }) else { throw CancellationError() }
        return context
    }

    func makeLyricsGenerationClient() async throws -> SwiftSonicClient {
        try await makeSwiftSonicClient()
    }
}
