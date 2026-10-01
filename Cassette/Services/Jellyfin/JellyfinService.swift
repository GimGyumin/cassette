// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import OSLog
import SwiftData

/// Active-server Jellyfin coordinator. Availability is probed independently from OpenSubsonic;
/// an unsupported/failed Jellyfin feature never marks the whole music server offline.
actor JellyfinService {
    private let serverService: any ServerServiceProtocol
    private let keychain: any KeychainServiceProtocol
    private let modelContainer: ModelContainer
    private let session: URLSession
    private let deviceIdentity: JellyfinDeviceIdentity
    private let capabilityTTL: TimeInterval = 6 * 60 * 60

    init(
        serverService: any ServerServiceProtocol,
        keychain: any KeychainServiceProtocol,
        modelContainer: ModelContainer,
        deviceIdentity: JellyfinDeviceIdentity,
        session: URLSession = .shared
    ) {
        self.serverService = serverService
        self.keychain = keychain
        self.modelContainer = modelContainer
        self.deviceIdentity = deviceIdentity
        self.session = session
    }

    func probeActiveServer() async throws -> JellyfinPublicSystemInfo {
        let client = try await makeClient(requireToken: false)
        return try await client.publicSystemInfo()
    }

    /// Login-screen probe that does not require a persisted/active server.
    func probeLoginEndpoint(
        serverBaseURL: URL,
        customHeaders: [String: String] = [:]
    ) async throws -> JellyfinLoginCapability {
        let client = try JellyfinClient(
            serverBaseURL: serverBaseURL,
            customHeaders: customHeaders,
            deviceID: deviceIdentity.id,
            deviceName: deviceIdentity.name,
            clientName: deviceIdentity.clientName,
            clientVersion: deviceIdentity.clientVersion,
            session: session
        )
        let info = try await client.publicSystemInfo()
        let quickConnect = (try? await client.quickConnectEnabled()) ?? false
        let publicUsers = (try? await client.publicUsers()) ?? []
        return JellyfinLoginCapability(
            serverName: info.serverName,
            version: info.version,
            quickConnectEnabled: quickConnect,
            publicUsers: publicUsers
        )
    }

    /// Completes optional Jellyfin authentication after the OpenSubsonic server record exists.
    /// The token has a separate Keychain key and never replaces the saved Subsonic password.
    @discardableResult
    func authenticateLogin(
        server: ServerSnapshot,
        password: String,
        customHeaders: [String: String]
    ) async throws -> JellyfinAuthenticationResult {
        guard let baseURL = URL(string: server.baseURL) else {
            throw JellyfinClientError.invalidBaseURL
        }
        let client = try JellyfinClient(
            serverBaseURL: baseURL,
            customHeaders: customHeaders,
            deviceID: deviceIdentity.id,
            deviceName: deviceIdentity.name,
            clientName: deviceIdentity.clientName,
            clientVersion: deviceIdentity.clientVersion,
            session: session
        )
        let result = try await client.authenticate(username: server.username, password: password)
        try await storeLoginToken(result.accessToken, serverID: server.id)
        _ = try await registerPlayer(baseURL: baseURL, token: result.accessToken, customHeaders: customHeaders)
        return result
    }

    func initiateQuickConnect(
        serverBaseURL: URL,
        customHeaders: [String: String] = [:]
    ) async throws -> JellyfinQuickConnectSession {
        let client = try makeClient(
            baseURL: serverBaseURL,
            token: nil,
            customHeaders: customHeaders
        )
        guard try await client.quickConnectEnabled() else {
            throw JellyfinClientError.quickConnectDisabled
        }
        let state = try await client.initiateQuickConnect()
        guard let code = state.code, !code.isEmpty,
              let secret = state.secret, !secret.isEmpty else {
            throw JellyfinClientError.malformedResponse
        }
        return JellyfinQuickConnectSession(
            code: code,
            secret: secret,
            serverBaseURL: serverBaseURL,
            customHeaders: customHeaders
        )
    }

    func waitForQuickConnect(
        _ quickConnect: JellyfinQuickConnectSession,
        timeout: Duration = .seconds(600)
    ) async throws -> JellyfinAuthenticationResult {
        let client = try makeClient(
            baseURL: quickConnect.serverBaseURL,
            token: nil,
            customHeaders: quickConnect.customHeaders
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let state = try await client.quickConnectState(secret: quickConnect.secret)
            if state.authenticated == true {
                let result = try await client.authenticateQuickConnect(secret: quickConnect.secret)
                try Task.checkCancellation()
                // Authentication already registers this device. A second lookup is needed only
                // for servers that omit User from the successful exchange response.
                let user: JellyfinUser
                if let authenticatedUser = result.user {
                    user = authenticatedUser
                } else {
                    user = try await registerPlayer(
                        baseURL: quickConnect.serverBaseURL,
                        token: result.accessToken,
                        customHeaders: quickConnect.customHeaders
                    )
                }
                return JellyfinAuthenticationResult(
                    accessToken: result.accessToken,
                    serverId: result.serverId,
                    user: result.user ?? user
                )
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw JellyfinClientError.quickConnectTimedOut
    }

    func storeLoginToken(_ token: String, serverID: UUID) async throws {
        try await keychain.store(token, forKey: Self.tokenKey(serverID))
    }

    /// Revalidates on a bounded TTL so rollback and Jellyfin ON/OFF changes are observed.
    /// Transient network failures preserve the last result and never mark OpenSubsonic offline.
    func capabilities(forceRefresh: Bool = false) async -> JellyfinCapabilitySnapshot? {
        guard let server = await MainActor.run(body: { serverService.state.activeServer }) else { return nil }
        if !forceRefresh, let cached = await capabilityRecord(serverID: server.id),
           Date().timeIntervalSince(cached.checkedAt) < capabilityTTL {
            return cached
        }
        do {
            let client = try await makeClient(requireToken: false)
            let info = try await client.publicSystemInfo()
            var features = (await capabilityRecord(serverID: server.id))?.featureSupport ?? [:]
            do {
                features[.quickConnect] = try await client.quickConnectEnabled() ? .supported : .unsupported
            } catch let error as JellyfinClientError {
                if error.isDefinitivelyUnsupported { features[.quickConnect] = .unsupported }
            } catch {}
            return await saveCapabilities(
                serverID: server.id,
                available: true,
                version: info.version,
                name: info.serverName,
                features: features
            )
        } catch let error as JellyfinClientError where error.isDefinitivelyUnsupported {
            return await saveCapabilities(
                serverID: server.id,
                available: false,
                version: nil,
                name: nil,
                features: [:]
            )
        } catch {
            Logger.server.debug("Jellyfin capability probe deferred: \(error.localizedDescription, privacy: .public)")
            return await capabilityRecord(serverID: server.id)
        }
    }

    /// Optional-feature boundary. Only a definitive missing endpoint disables that feature;
    /// authentication and transport failures remain retryable and do not affect other APIs.
    func perform<Value: Sendable>(
        feature: JellyfinFeature,
        operation: @Sendable (JellyfinClient) async throws -> Value
    ) async throws -> Value {
        guard let server = await MainActor.run(body: { serverService.state.activeServer }) else {
            throw CassetteError.serverNotConfigured
        }
        let client = try await authenticatedClient()
        do {
            let value = try await operation(client)
            await record(feature: feature, support: .supported, serverID: server.id)
            return value
        } catch let error as JellyfinClientError {
            if error.isDefinitivelyUnsupported {
                await record(feature: feature, support: .unsupported, serverID: server.id)
            }
            throw error
        }
    }

    func instantMix(
        canonicalItemID: String,
        source: JellyfinInstantMixSource,
        limit: Int = 50
    ) async throws -> [DisplayableSong] {
        guard let jellyfinID = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: canonicalItemID) else {
            throw JellyfinClientError.malformedResponse
        }
        let response = try await perform(feature: .instantMix) { client in
            try await client.instantMix(itemID: jellyfinID, source: source, limit: limit)
        }
        return response.items.compactMap(DisplayableSong.init(jellyfinItem:))
    }

    @discardableResult
    func authenticateWithSubsonicCredentials() async throws -> JellyfinAuthenticationResult {
        guard let server = await MainActor.run(body: { serverService.state.activeServer }) else {
            throw CassetteError.serverNotConfigured
        }
        let credentials = try await serverService.activeCredentials()
        if let token = credentials.jellyfinAccessToken, !token.isEmpty {
            try await storeLoginToken(token, serverID: server.id)
            guard let baseURL = URL(string: server.baseURL) else {
                throw JellyfinClientError.invalidBaseURL
            }
            _ = try await registerPlayer(baseURL: baseURL, token: token, customHeaders: credentials.customHeaders)
            let client = try makeClient(baseURL: baseURL, token: token, customHeaders: credentials.customHeaders)
            let user = try await client.currentUser()
            return JellyfinAuthenticationResult(accessToken: token, serverId: nil, user: user)
        }
        let client = try await makeClient(requireToken: false)
        let result = try await client.authenticate(username: server.username, password: credentials.password)
        try await storeLoginToken(result.accessToken, serverID: server.id)
        if let baseURL = URL(string: server.baseURL) {
            _ = try await registerPlayer(baseURL: baseURL, token: result.accessToken, customHeaders: credentials.customHeaders)
        }
        return result
    }

    func authenticatedClient() async throws -> JellyfinClient {
        do {
            return try await makeClient(requireToken: true)
        } catch JellyfinClientError.authenticationRequired {
            _ = try await authenticateWithSubsonicCredentials()
            return try await makeClient(requireToken: true)
        }
    }

    func clearToken(serverID: UUID) async {
        try? await keychain.delete(forKey: Self.tokenKey(serverID))
    }

    private func makeClient(requireToken: Bool) async throws -> JellyfinClient {
        guard let server = await MainActor.run(body: { serverService.state.activeServer }),
              let baseURL = URL(string: server.baseURL) else {
            throw CassetteError.serverNotConfigured
        }
        let credentials = try? await serverService.activeCredentials()
        let token = try await keychain.retrieve(String.self, forKey: Self.tokenKey(server.id))
            ?? credentials?.jellyfinAccessToken
        if requireToken && (token?.isEmpty != false) { throw JellyfinClientError.authenticationRequired }
        let headers = credentials?.customHeaders ?? [:]
        return try makeClient(
            baseURL: baseURL,
            token: token,
            customHeaders: headers
        )
    }

    private func makeClient(
        baseURL: URL,
        token: String?,
        customHeaders: [String: String]
    ) throws -> JellyfinClient {
        try JellyfinClient(
            serverBaseURL: baseURL,
            accessToken: token,
            customHeaders: customHeaders,
            deviceID: deviceIdentity.id,
            deviceName: deviceIdentity.name,
            clientName: deviceIdentity.clientName,
            clientVersion: deviceIdentity.clientVersion,
            session: session
        )
    }

    private func registerPlayer(
        baseURL: URL,
        token: String,
        customHeaders: [String: String]
    ) async throws -> JellyfinUser {
        let client = try makeClient(baseURL: baseURL, token: token, customHeaders: customHeaders)
        return try await client.currentUser()
    }

    private static func tokenKey(_ serverID: UUID) -> String {
        "cassette.jellyfin.token.\(serverID.uuidString)"
    }

    @MainActor
    private func capabilityRecord(serverID: UUID) -> JellyfinCapabilitySnapshot? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<JellyfinCapabilityRecord>(predicate: #Predicate {
            $0.serverID == serverID
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.snapshot
    }

    @MainActor
    private func saveCapabilities(
        serverID: UUID,
        available: Bool,
        version: String?,
        name: String?,
        features: [JellyfinFeature: JellyfinFeatureSupport]
    ) -> JellyfinCapabilitySnapshot {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<JellyfinCapabilityRecord>(predicate: #Predicate {
            $0.serverID == serverID
        })
        descriptor.fetchLimit = 1
        let record: JellyfinCapabilityRecord
        if let existing = try? context.fetch(descriptor).first {
            record = existing
            record.isAvailable = available
            record.serverVersion = version
            record.serverName = name
            record.checkedAt = Date()
            record.featureSupport = features
        } else {
            record = JellyfinCapabilityRecord(
                serverID: serverID,
                isAvailable: available,
                serverVersion: version,
                serverName: name,
                featureSupport: features
            )
            context.insert(record)
        }
        try? context.save()
        return record.snapshot
    }

    @MainActor
    private func record(feature: JellyfinFeature, support: JellyfinFeatureSupport, serverID: UUID) {
        let current = capabilityRecord(serverID: serverID)
        var features = current?.featureSupport ?? [:]
        features[feature] = support
        _ = saveCapabilities(
            serverID: serverID,
            available: current?.isAvailable ?? true,
            version: current?.serverVersion,
            name: current?.serverName,
            features: features
        )
    }
}

private extension DisplayableSong {
    /// `nonisolated` so it can be passed as a function value (`compactMap`) from the
    /// Jellyfin actor; the mapper only reads value types.
    nonisolated init?(jellyfinItem item: JellyfinItem) {
        guard item.type == JellyfinItemType.audio.rawValue,
              let canonicalID = NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: item.id) else {
            return nil
        }
        let media = item.mediaSources?.first
        self.init(
            id: canonicalID,
            title: item.name ?? String(localized: "Unknown Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            artist: item.artists?.first ?? item.albumArtist,
            albumId: item.albumId.flatMap(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID:)),
            albumName: item.album,
            artistId: item.artistItems?.first?.id.flatMap(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID:)),
            genre: item.genres?.first,
            duration: TimeInterval(item.runTimeTicks ?? 0) / 10_000_000,
            trackNumber: item.indexNumber,
            discNumber: item.parentIndexNumber,
            coverArtId: canonicalID,
            audioFormat: media?.container?.uppercased(),
            bitRate: media?.bitrate,
            replayGainTrackGain: item.normalizationGain,
            replayGainAlbumGain: item.albumNormalizationGain
        )
    }
}

nonisolated struct JellyfinLoginCapability: Sendable, Equatable {
    let serverName: String?
    let version: String?
    let quickConnectEnabled: Bool
    let publicUsers: [JellyfinUser]
}

nonisolated struct JellyfinQuickConnectSession: Sendable, Equatable {
    let code: String
    let secret: String
    let serverBaseURL: URL
    let customHeaders: [String: String]
}

private extension JellyfinClientError {
    var isDefinitivelyUnsupported: Bool {
        guard case let .unavailable(statusCode) = self else { return false }
        return statusCode == 404 || statusCode == 405 || statusCode == 501
    }
}
