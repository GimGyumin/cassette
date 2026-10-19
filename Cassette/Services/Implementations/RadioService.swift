// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic
import OSLog

actor RadioService: RadioServiceProtocol {
    private let serverService: any ServerServiceProtocol
    private var cachedClient: SwiftSonicClient?
    private var cachedServerId: UUID?
    private var stationsCache: [InternetRadioStation]?
    private var identity: ServerRequestIdentity?
    private var generation: UInt64 = 0

    init(serverService: any ServerServiceProtocol) {
        self.serverService = serverService
    }

    // MARK: - Client

    private func client() async throws -> SwiftSonicClient {
        let token = try await MainActor.run {
            guard let sid = serverService.state.activeServer?.id else { throw CassetteError.serverNotConfigured }
            return try serverService.state.requestIdentity(for: sid)
        }
        if let cached = cachedClient, identity == token {
            return cached
        }
        if identity != token {
            await invalidateClientCache()
            identity = token
        }
        let revision = generation
        let fresh = try await serverService.makeSwiftSonicClient()
        guard await MainActor.run(body: { serverService.state.requestIsCurrent(token) }), revision == generation else { throw CancellationError() }
        cachedClient = fresh
        cachedServerId = token.serverID
        identity = token
        return fresh
    }

    // MARK: - Read

    func listStations(forceRefresh: Bool = false) async throws -> [InternetRadioStation] {
        let client = try await client()
        let token = identity
        let revision = generation
        if !forceRefresh, let cached = stationsCache { return cached }
        let stations = try await client.getInternetRadioStations()
        try Task.checkCancellation()
        guard let token, await MainActor.run(body: { serverService.state.requestIsCurrent(token) }),
              revision == generation, identity == token else { throw CancellationError() }
        stationsCache = stations
        Logger.radio.debug("Fetched \(stations.count) radio station(s).")
        return stations
    }

    func cachedStations() async -> [InternetRadioStation]? {
        guard let identity, await MainActor.run(body: { serverService.state.requestIsCurrent(identity) }) else { return nil }
        return stationsCache
    }

    func clearCache() async {
        generation &+= 1
        stationsCache = nil
        Logger.radio.debug("Radio station cache cleared.")
    }

    func invalidateClientCache() async {
        generation &+= 1
        identity = nil
        cachedClient = nil
        cachedServerId = nil
        stationsCache = nil
    }
}
