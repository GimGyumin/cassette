// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import SwiftSonic
import OSLog

actor ServerService: ServerServiceProtocol {
    nonisolated let state: ServerState

    private let jellyfinSession: URLSession
    private let keychain: any KeychainServiceProtocol
    private let modelContainer: ModelContainer
    private let cacheService: any CacheServiceProtocol
    /// Joins concurrent Keychain+URLSession client builds — cold start used to stampede this.
    private var clientGeneration: UInt64 = 0
    private var clientInFlight: Task<SwiftSonicClient, Error>?
    /// Reused client for the current active server, so playback state transitions and
    /// periodic reports do not rebuild Keychain + URLSession every time.
    private var cachedClient: SwiftSonicClient?
    private var cachedClientServerID: UUID?

    init(state: ServerState, keychain: any KeychainServiceProtocol, modelContainer: ModelContainer, cacheService: any CacheServiceProtocol, jellyfinSession: URLSession = .shared) {
        self.jellyfinSession = jellyfinSession
        self.state = state
        self.keychain = keychain
        self.modelContainer = modelContainer
        self.cacheService = cacheService
    }

    func addServer(
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        try validateHeaders(customHeaders)
        let creds = ServerCredentials(password: password, customHeaders: customHeaders)
        try await persistServer(
            displayName: displayName,
            baseURL: baseURL,
            username: username,
            credentials: creds
        )
    }

    func addServerWithJellyfinToken(
        displayName: String,
        baseURL: String,
        username: String,
        jellyfinAccessToken: String,
        customHeaders: [String: String]
    ) async throws {
        try validateHeaders(customHeaders)
        guard let serverURL = URL(string: baseURL) else {
            throw ConnectionTestError.invalidURL
        }
        let client = try await jellyfinClient(url: serverURL, token: jellyfinAccessToken, headers: customHeaders)
        let user = try await client.currentUser()
        guard user.name == username, !user.id.isEmpty else {
            throw JellyfinClientError.missingAuthenticatedUser
        }
        try Task.checkCancellation()

        let creds = ServerCredentials(
            password: "",
            customHeaders: customHeaders,
            jellyfinAccessToken: jellyfinAccessToken
        )
        try await persistServer(
            displayName: displayName,
            baseURL: baseURL,
            username: username,
            credentials: creds
        )
    }

    private func persistServer(
        displayName: String,
        baseURL: String,
        username: String,
        credentials: ServerCredentials
    ) async throws {
        let configId = UUID()
        let credKey = ServerCredentials.keychainKey(for: configId)

        // Keychain first: if SwiftData save fails below, we can roll back with a single delete.
        try await keychain.store(credentials, forKey: credKey)

        do {
            try Task.checkCancellation()
            try await MainActor.run {
                try Task.checkCancellation()
                let context = ModelContext(modelContainer)
                let existing = try context.fetch(FetchDescriptor<ServerConfig>())
                // Deleting the active server can leave other, inactive records.
                // A successful new sign-in must restore an active server in that case.
                let shouldActivate = !existing.contains(where: \.isActive)
                let config = ServerConfig(
                    id: configId,
                    displayName: displayName,
                    baseURL: baseURL,
                    username: username,
                    isActive: shouldActivate
                )
                context.insert(config)
                try context.save()
                let snapshot = ServerSnapshot(from: config)
                state.servers = existing.map { ServerSnapshot(from: $0) } + [snapshot]
                state.activeServer = shouldActivate
                    ? snapshot
                    : existing.first(where: \.isActive).map { ServerSnapshot(from: $0) }
            }
        } catch {
            try? await keychain.delete(forKey: credKey)
            throw error
        }
        await refreshCredentialAvailability()
    }

    func removeServer(id: UUID) async throws {
        let credKey = ServerCredentials.keychainKey(for: id)

        try await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<ServerConfig>(
                predicate: #Predicate { $0.id == id }
            )
            guard let config = try context.fetch(descriptor).first else {
                throw CassetteError.serverNotFound(id: id)
            }
            context.delete(config)
            try context.save()
            state.servers.removeAll { $0.id == id }
            if state.activeServer?.id == id {
                state.activeServer = nil
                state.isConnected = false
            }
        }

        await refreshCredentialAvailability()

        // Best-effort: an orphaned Keychain entry is harmless if this fails.
        try? await keychain.delete(forKey: credKey)
    }

    func setActiveServer(id: UUID) async throws {
        let allServerIds = try await MainActor.run {
            let context = ModelContext(modelContainer)
            let all = try context.fetch(FetchDescriptor<ServerConfig>())
            guard let target = all.first(where: { $0.id == id }) else {
                throw CassetteError.serverNotFound(id: id)
            }
            for config in all { config.isActive = false }
            target.isActive = true
            try context.save()
            state.activeServer = ServerSnapshot(from: target)
            state.isConnected = false
            return all.map(\.id)
        }

        await refreshCredentialAvailability()

        // Best-effort: clear the audio cache for every server that is no longer active.
        let othersToClean = allServerIds.filter { $0 != id }
        guard !othersToClean.isEmpty else {
            Logger.server.debug("No other servers to clean cache for at switch.")
            return
        }
        for serverId in othersToClean {
            await cacheService.clearAllForServer(serverId)
        }
        Logger.server.info("Cleared cache for \(othersToClean.count) non-active server(s) at switch.")
    }

    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {
        clientGeneration &+= 1
        clientInFlight?.cancel()
        clientInFlight = nil
        cachedClient = nil
        cachedClientServerID = nil
        try validateHeaders(headers)
        let credKey = ServerCredentials.keychainKey(for: id)
        guard let existing = try await keychain.retrieve(ServerCredentials.self, forKey: credKey) else {
            throw CassetteError.serverNotFound(id: id)
        }
        let updated = ServerCredentials(
            password: existing.password,
            customHeaders: headers,
            jellyfinAccessToken: existing.jellyfinAccessToken
        )
        try await keychain.store(updated, forKey: credKey)
    }

    func updateServer(
        id: UUID,
        displayName: String,
        baseURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        clientGeneration &+= 1
        clientInFlight?.cancel()
        clientInFlight = nil
        cachedClient = nil
        cachedClientServerID = nil
        try validateHeaders(customHeaders)

        let credKey = ServerCredentials.keychainKey(for: id)
        let creds = ServerCredentials(password: password, customHeaders: customHeaders)
        let previousCredentials = try await keychain.retrieve(ServerCredentials.self, forKey: credKey)

        // Keychain first — mirrors addServer rollback strategy.
        try await keychain.store(creds, forKey: credKey)

        do {
            try await MainActor.run {
                let context = ModelContext(modelContainer)
                let descriptor = FetchDescriptor<ServerConfig>(predicate: #Predicate { $0.id == id })
                guard let config = try context.fetch(descriptor).first else {
                    throw CassetteError.serverNotFound(id: id)
                }
                config.displayName = displayName
                config.baseURL = baseURL
                config.username = username
                try context.save()
                let snapshot = ServerSnapshot(from: config)
                if let idx = state.servers.firstIndex(where: { $0.id == id }) {
                    state.servers[idx] = snapshot
                }
                if state.activeServer?.id == id {
                    state.activeServer = snapshot
                }
                state.needsCredentialReentry = false
                if state.activeServer?.id == id { state.needsSubsonicVerification = false }
            }
            clientGeneration &+= 1
            clientInFlight?.cancel()
            clientInFlight = nil
            cachedClient = nil
            cachedClientServerID = nil
            await MainActor.run {
                NotificationCenter.default.post(name: .cassetteServerCredentialsChanged, object: nil)
            }
        } catch {
            do {
                if let previousCredentials {
                    try await keychain.store(previousCredentials, forKey: credKey)
                } else {
                    try await keychain.delete(forKey: credKey)
                }
            } catch {
                Logger.keychain.error(
                    "Failed to restore credentials after server update failure for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
    }

    func loadPersistedState() async {
        do {
            let serverIDs = try await MainActor.run {
                let context = ModelContext(modelContainer)
                let configs = try context.fetch(FetchDescriptor<ServerConfig>())
                state.servers = configs.map { ServerSnapshot(from: $0) }
                state.activeServer = configs.first(where: { $0.isActive }).map { ServerSnapshot(from: $0) }
                state.isLoadingPersistedState = false
                return configs.map(\.id)
            }
            await migrateCredentialsAccessibility(for: serverIDs)
            await refreshCredentialAvailability()
        } catch {
            await MainActor.run { state.isLoadingPersistedState = false }
        }
    }

    /// Checks Keychain for the active server password and updates `needsCredentialReentry`.
    func refreshCredentialAvailability() async {
        let activeID = await MainActor.run { state.activeServer?.id }
        guard let activeID else {
            await MainActor.run {
                state.needsCredentialReentry = false
                state.needsSubsonicVerification = false
            }
            return
        }
        let key = ServerCredentials.keychainKey(for: activeID)
        do {
            let creds = try await keychain.retrieve(ServerCredentials.self, forKey: key)
            let missing = creds == nil || (
                creds?.password.isEmpty == true && creds?.jellyfinAccessToken?.isEmpty != false
            )
            await MainActor.run {
                guard state.activeServer?.id == activeID else { return }
                state.needsCredentialReentry = missing
                state.needsSubsonicVerification = creds?.password.isEmpty == true && creds?.jellyfinAccessToken?.isEmpty == false
            }
            if missing {
                Logger.server.error(
                    "Active server \(activeID, privacy: .public) has no Keychain password — needsCredentialReentry=true"
                )
            }
        } catch {
            await MainActor.run { state.needsCredentialReentry = true }
            Logger.server.error("Credential availability check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-writes existing Keychain items with AfterFirstUnlock accessibility so
    /// that lock screen playback transitions can read credentials during KI-2 fix.
    /// Idempotent: safe to call on every cold start. Never blocks app boot.
    private func migrateCredentialsAccessibility(for serverIDs: [UUID]) async {
        for id in serverIDs {
            let key = ServerCredentials.keychainKey(for: id)
            do {
                guard let creds = try await keychain.retrieve(ServerCredentials.self, forKey: key) else {
                    Logger.server.warning("Keychain migration: no credential found for server id=\(id, privacy: .public), skipping")
                    continue
                }
                try await keychain.store(creds, forKey: key)
                Logger.server.info("Keychain migration: credential migrated for server id=\(id, privacy: .public)")
            } catch {
                Logger.server.warning("Keychain migration: skipped server id=\(id, privacy: .public) — \(error, privacy: .public)")
            }
        }
    }

    func testConnection() async throws {
        let client = try await makeSwiftSonicClient()
        try await client.ping()
    }

    func testConnection(
        url: String,
        username: String,
        password: String,
        customHeaders: [String: String]
    ) async throws {
        guard let serverURL = URL(string: url.trimmingCharacters(in: .whitespaces)),
              serverURL.scheme != nil, serverURL.host != nil else {
            throw ConnectionTestError.invalidURL
        }
        let transport = CustomHeadersTransport(headers: customHeaders)
        let client = SwiftSonicClient(
            configuration: ServerConfiguration(serverURL: serverURL, username: username, password: password),
            transport: transport,
            retryPolicy: .none,
            logSubsystem: "app.cassette.server"
        )
        do {
            try await client.ping()
        } catch {
            throw mapToConnectionTestError(error)
        }
        do {
            _ = try await client.getUser(username: username)
        } catch {
            throw mapToConnectionTestError(error)
        }
    }

    func makeSwiftSonicClient() async throws -> SwiftSonicClient {
        if let cachedClient, let cachedClientServerID,
           await MainActor.run(body: { state.activeServer?.id }) == cachedClientServerID {
            return cachedClient
        }
        if let clientInFlight {
            return try await clientInFlight.value
        }
        let generation = clientGeneration
        let serverID = await MainActor.run { state.activeServer?.id }
        let task = Task {
            try await self.buildSwiftSonicClient()
        }
        clientInFlight = task
        do {
            let client = try await task.value
            guard generation == clientGeneration,
                  await MainActor.run(body: { state.activeServer?.id }) == serverID else {
                throw CancellationError()
            }
            clientInFlight = nil
            cachedClient = client
            cachedClientServerID = serverID
            return client
        } catch {
            if generation == clientGeneration { clientInFlight = nil }
            throw error
        }
    }

    func makeLyricsGenerationClient() async throws -> SwiftSonicClient {
        guard let snapshot = await MainActor.run(body: { state.activeServer }),
              let url = URL(string: snapshot.baseURL) else {
            throw CassetteError.serverNotConfigured
        }
        let credentials = try await activeCredentials()
        guard !credentials.password.isEmpty else { throw CassetteError.credentialsMissing }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        let transport = CustomHeadersTransport(
            base: URLSessionTransport(configuration: configuration), headers: credentials.customHeaders
        )
        return SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: url,
                auth: .tokenAuth(username: snapshot.username, password: credentials.password, reusesSalt: false),
                clientName: "Cassette", requestTimeout: 90, resourceTimeout: 120
            ), transport: transport, retryPolicy: .none
        )
    }

    /// Warms Keychain + client construction so the first Home `getAlbumList2` isn't blocked on it.
    func preWarmClient() async {
        do {
            _ = try await makeSwiftSonicClient()
            Logger.server.debug("preWarmClient: ready")
        } catch {
            Logger.server.debug("preWarmClient: skipped — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func buildSwiftSonicClient() async throws -> SwiftSonicClient {
        let snapshot = await MainActor.run { state.activeServer }
        Logger.server.debug("makeSwiftSonicClient — activeServer=\(String(describing: snapshot?.baseURL), privacy: .public)")
        guard let snapshot else {
            Logger.server.error("makeSwiftSonicClient: activeServer is nil → serverNotConfigured")
            throw CassetteError.serverNotConfigured
        }

        let creds = try await keychain.retrieve(
            ServerCredentials.self,
            forKey: ServerCredentials.keychainKey(for: snapshot.id)
        )
        guard let creds,
              !creds.password.isEmpty || creds.jellyfinAccessToken?.isEmpty == false else {
            await MainActor.run { state.needsCredentialReentry = true }
            Logger.server.error(
                "makeSwiftSonicClient: Keychain password missing for \(snapshot.id, privacy: .public) → credentialsMissing"
            )
            throw CassetteError.credentialsMissing
        }

        guard let url = URL(string: snapshot.baseURL) else {
            throw CassetteError.invalidServerURL(snapshot.baseURL)
        }

        if creds.password.isEmpty, let token = creds.jellyfinAccessToken, !token.isEmpty {
            let client = try await jellyfinClient(url: url, token: token, headers: creds.customHeaders)
            let user = try await client.currentUser()
            return JellyfinMusicTransport(client: client, user: user).makeMusicClient(serverURL: url)
        }
        let transport = CustomHeadersTransport(headers: creds.customHeaders)
        // No retries: a hung Subsonic response already costs the full request timeout;
        // retrying timeouts turns a ~15s cold-start stall into ~45s+.
        let auth: AuthMethod
        if !creds.password.isEmpty {
            auth = .tokenAuth(username: snapshot.username, password: creds.password, reusesSalt: false)

        } else {
            throw CassetteError.credentialsMissing
        }
        return SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: url,
                auth: auth,
                clientName: "Cassette",
                requestTimeout: 15,
                resourceTimeout: 20
            ),
            transport: transport,
            retryPolicy: .none,
            logSubsystem: "app.cassette.server"
        )
    }

    private func jellyfinClient(url: URL, token: String, headers: [String: String]) async throws -> JellyfinClient {
        let identity = await MainActor.run { JellyfinDeviceIdentity.current() }
        return try JellyfinClient(serverBaseURL: url, accessToken: token, customHeaders: headers,
                              deviceID: identity.id, deviceName: identity.name,
                              clientName: identity.clientName, clientVersion: identity.clientVersion,
                              session: jellyfinSession)
    }

    func activeCredentials() async throws -> ServerCredentials {
        let snapshot = await MainActor.run { state.activeServer }
        guard let snapshot else { throw CassetteError.serverNotConfigured }

        guard let creds = try await keychain.retrieve(
            ServerCredentials.self,
            forKey: ServerCredentials.keychainKey(for: snapshot.id)
        ), !creds.password.isEmpty || creds.jellyfinAccessToken?.isEmpty == false else {
            await MainActor.run { state.needsCredentialReentry = true }
            throw CassetteError.credentialsMissing
        }

        return creds
    }

    // MARK: - Private

    func mapToConnectionTestError(_ error: Error) -> ConnectionTestError {
        guard let sonic = error as? SwiftSonicError else {
            let e = error as NSError
            Logger.server.error("Connection test failed — non-SwiftSonic error: domain=\(e.domain, privacy: .public) code=\(e.code, privacy: .public)")
            return .unknown(domain: e.domain, code: e.code)
        }

        // Log the raw underlying error details before any mapping.
        switch sonic {
        case .network(let urlError):
            Logger.server.error("Connection test failed — URLError code=\(urlError.code.rawValue, privacy: .public)")
        case .httpError(let statusCode, let endpoint, let serverHost):
            Logger.server.error("Connection test failed — HTTP \(statusCode, privacy: .public) endpoint=\(endpoint, privacy: .public) host=\(serverHost ?? "nil", privacy: .public)")
        case .api(let apiError):
            Logger.server.error("Connection test failed — Subsonic API error code=\(apiError.code.rawValue, privacy: .public) endpoint=\(apiError.endpoint, privacy: .public)")
        case .decoding(_, let rawData):
            Logger.server.error("Connection test failed — decoding error, rawData.count=\(rawData.count, privacy: .public)")
        case .rateLimited(let retryAfter, let endpoint, let serverHost):
            let retryAfterStr = retryAfter.map { "\($0)" } ?? "nil"
            Logger.server.error("Connection test failed — rate limited endpoint=\(endpoint, privacy: .public) host=\(serverHost ?? "nil", privacy: .public) retryAfterSecs=\(retryAfterStr, privacy: .public)")
        case .invalidConfiguration(let reason):
            Logger.server.error("Connection test failed — invalidConfiguration: \(reason, privacy: .public)")
        case .insecureRedirect(let from, let to):
            Logger.server.error("Connection test failed — insecureRedirect from=\(from.host ?? "nil", privacy: .public) to=\(to.host ?? "nil", privacy: .public)")
        }

        switch sonic {
        case .network(let urlError):
            if sonic.isDNSFailure { return .dnsFailure }
            if sonic.isCertificateError { return .certificate }
            switch urlError.code {
            case .appTransportSecurityRequiresSecureConnection:
                return .atsBlocked
            case .timedOut:
                return .timeout
            default:
                return .cannotConnect
            }
        case .httpError(let statusCode, _, _):
            if statusCode == 401 || statusCode == 403 { return .unauthorized }
            return .httpError(statusCode: statusCode)
        case .api(let apiError):
            if sonic.isAuthenticationFailure { return .unauthorized }
            return .subsonicError(code: apiError.code, message: apiError.message)
        case .decoding:
            return .notSubsonicServer
        case .rateLimited:
            return .httpError(statusCode: 429)
        case .invalidConfiguration:
            return .invalidConfiguration
        case .insecureRedirect:
            return .insecureRedirect
        }
    }

    private func validateHeaders(_ headers: [String: String]) throws {
        for (key, value) in headers {
            guard HeaderValidator.isValidName(key) else {
                throw CassetteError.invalidHeaderName(key: key)
            }
            guard HeaderValidator.isValidValue(value) else {
                throw CassetteError.invalidHeaderValue(key: key)
            }
        }
    }
}
