// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

nonisolated enum JellyfinLoginStatus: Equatable, Sendable {
    case idle
    case checking
    case available(serverName: String?, version: String?, quickConnectEnabled: Bool)
    case unavailable
}

nonisolated enum JellyfinQuickConnectLoginState: Equatable, Sendable {
    case idle
    case starting
    case awaitingApproval(code: String)
    case completing
    case failed(message: String)
}

nonisolated enum JellyfinLANDiscoveryState: Equatable, Sendable {
    case idle
    case searching
    case finished
    /// The system refused every probe — Local Network access is off for Cassette.
    case permissionDenied
    case failed
}

@Observable
@MainActor
final class OnboardingViewModel {
    var serverURL: String = ""
    var username: String = ""
    var password: String = ""
    var customHeaders: [CustomHeaderEntry] = []
    var isLoading: Bool = false
    var connectionError: ConnectionTestError?
    var jellyfinStatus: JellyfinLoginStatus = .idle
    var jellyfinPublicUsers: [JellyfinUser] = []
    var quickConnectState: JellyfinQuickConnectLoginState = .idle
    var discoveredServers: [JellyfinDiscoveredServer] = []
    var discoveryState: JellyfinLANDiscoveryState = .idle

    /// Display name derived from the URL host, falling back to the raw URL string.
    var derivedDisplayName: String {
        ServerEndpointNormalizer.openSubsonicBaseURL(from: serverURL)?.host ?? serverURL
    }

    /// True once the address looks like a URL with a host — reveals username / password.
    /// (Any non-empty string used to flip this and re-layout the Form on every keystroke while the
    /// keyboard was up, which spams UIKit `TUIPredictionViewCell` Autolayout warnings.)
    var hasEnteredServerURL: Bool {
        ServerEndpointNormalizer.openSubsonicBaseURL(from: serverURL) != nil
    }

    var supportsQuickConnect: Bool {
        if case .available(_, _, true) = jellyfinStatus { return true }
        return false
    }

    var canSubmit: Bool {
        hasEnteredServerURL &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    var isHTTP: Bool {
        ServerEndpointNormalizer.openSubsonicBaseURL(from: serverURL)?.scheme == "http"
    }

    private var quickConnectGeneration = 0
    private let serverService: any ServerServiceProtocol
    private let jellyfinService: JellyfinService?
    private let jellyfinDiscoveryService: JellyfinLANDiscoveryService?

    init(
        serverService: any ServerServiceProtocol,
        jellyfinService: JellyfinService? = nil,
        jellyfinDiscoveryService: JellyfinLANDiscoveryService? = nil
    ) {
        self.serverService = serverService
        self.jellyfinService = jellyfinService
        self.jellyfinDiscoveryService = jellyfinDiscoveryService
    }

    var jellyfinProbeKey: Int {
        var hasher = Hasher()
        hasher.combine(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        for header in customHeaders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(header.key)
            hasher.combine(header.value)
        }
        return hasher.finalize()
    }

    func probeJellyfin() async {
        guard let jellyfinService,
              let baseURL = ServerEndpointNormalizer.openSubsonicBaseURL(from: serverURL) else {
            jellyfinStatus = .idle
            jellyfinPublicUsers = []
            return
        }
        let probeKey = jellyfinProbeKey
        jellyfinStatus = .checking
        do {
            try await Task.sleep(for: .milliseconds(450))
            try Task.checkCancellation()
            let capability = try await jellyfinService.probeLoginEndpoint(
                serverBaseURL: baseURL,
                customHeaders: headersDict()
            )
            try Task.checkCancellation()
            guard probeKey == jellyfinProbeKey else { return }
            jellyfinStatus = .available(
                serverName: capability.serverName,
                version: capability.version,
                quickConnectEnabled: capability.quickConnectEnabled
            )
            jellyfinPublicUsers = capability.publicUsers
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, probeKey == jellyfinProbeKey else { return }
            jellyfinStatus = .unavailable
            jellyfinPublicUsers = []
        }
    }

    func selectPublicUser(_ user: JellyfinUser) {
        guard let name = user.name, !name.isEmpty else { return }
        username = name
    }

    /// Finds compatible servers on the local network.
    ///
    /// Always on — there is no user-facing switch for it. The sign-in surface searches as soon as it
    /// appears and the options sheet offers a retry, so a toggle would only ever be left on.
    func discoverLANServers() async {
        guard let jellyfinDiscoveryService else {
            discoveryState = .failed
            return
        }
        guard discoveryState != .searching else { return }
        discoveryState = .searching
        do {
            let servers = try await jellyfinDiscoveryService.discover()
            try Task.checkCancellation()
            discoveredServers = servers
            discoveryState = .finished
        } catch is CancellationError {
            discoveryState = .idle
            return
        } catch JellyfinLANDiscoveryError.permissionDenied {
            // Every probe was refused: the message must point at the permission, not at the server.
            discoveredServers = []
            discoveryState = .permissionDenied
        } catch {
            discoveredServers = []
            discoveryState = .failed
        }
    }

    func useDiscoveredServer(_ server: JellyfinDiscoveredServer) {
        serverURL = server.address
    }

    @discardableResult
    func signInWithQuickConnect() async -> Bool {
        guard !isLoading,
              let jellyfinService,
              let normalizedAddress = ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: serverURL),
              let baseURL = URL(string: normalizedAddress) else { return false }
        quickConnectGeneration += 1
        let generation = quickConnectGeneration
        let probeKey = jellyfinProbeKey
        connectionError = nil
        quickConnectState = .starting
        isLoading = true
        defer { if generation == quickConnectGeneration { isLoading = false } }
        func checkCurrentAttempt() throws {
            try Task.checkCancellation()
            guard generation == quickConnectGeneration, probeKey == jellyfinProbeKey else {
                throw CancellationError()
            }
        }

        let headers = headersDict()
        do {
            let session = try await jellyfinService.initiateQuickConnect(
                serverBaseURL: baseURL,
                customHeaders: headers
            )
            try checkCurrentAttempt()
            quickConnectState = .awaitingApproval(code: session.code)
            let result = try await jellyfinService.waitForQuickConnect(session)
            try checkCurrentAttempt()
            quickConnectState = .completing
            guard let username = result.user?.name, !username.isEmpty else {
                throw JellyfinClientError.missingAuthenticatedUser
            }
            self.username = username
            try await serverService.addServerWithJellyfinToken(
                displayName: jellyfinServerDisplayName(fallback: normalizedAddress),
                baseURL: normalizedAddress,
                username: username,
                jellyfinAccessToken: result.accessToken,
                customHeaders: headers
            )
            guard let server = serverService.state.servers.last(where: {
                $0.baseURL == normalizedAddress && $0.username == username
            }) else {
                throw CassetteError.serverNotConfigured
            }
            try? await jellyfinService.storeLoginToken(result.accessToken, serverID: server.id)
            return true
        } catch {
            guard generation == quickConnectGeneration else { return false }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                quickConnectState = .idle
            } else {
                quickConnectState = .failed(message: quickConnectErrorMessage(error))
            }
            return false
        }
    }

    func resetQuickConnect() {
        if quickConnectState != .idle { isLoading = false }
        quickConnectGeneration += 1
        quickConnectState = .idle
    }

    func testConnection() async {
        guard !isLoading else { return }
        connectionError = nil
        isLoading = true
        defer { isLoading = false }

        guard let normalizedURL = ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: serverURL) else {
            connectionError = .invalidURL
            return
        }

        do {
            try await serverService.testConnection(
                url: normalizedURL,
                username: username,
                password: password,
                customHeaders: headersDict()
            )
        } catch let error as ConnectionTestError {
            connectionError = error
        } catch {
            let e = error as NSError
            connectionError = .unknown(domain: e.domain, code: e.code)
        }
    }

    /// Validates, tests, and persists the server in a single flow.
    /// Return success only after the server is persisted and active. A duplicate
    /// submit while the first request is running must not advance onboarding.
    @discardableResult
    func addServer() async -> Bool {
        guard !isLoading, canSubmit else { return false }
        connectionError = nil
        isLoading = true
        defer { isLoading = false }

        guard let trimmedURL = ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: serverURL) else {
            connectionError = .invalidURL
            return false
        }
        let headers = headersDict()

        do {
            try await serverService.testConnection(
                url: trimmedURL,
                username: username,
                password: password,
                customHeaders: headers
            )
        } catch let error as ConnectionTestError {
            connectionError = error
            return false
        } catch {
            let e = error as NSError
            connectionError = .unknown(domain: e.domain, code: e.code)
            return false
        }

        do {
            try await serverService.addServer(
                displayName: derivedDisplayName,
                baseURL: trimmedURL,
                username: username,
                password: password,
                customHeaders: headers
            )
            guard serverService.state.activeServer != nil else {
                throw CassetteError.serverNotConfigured
            }
            await configureJellyfinIfAvailable(
                baseURL: trimmedURL,
                username: username,
                password: password,
                headers: headers
            )
            return true
        } catch {
            let e = error as NSError
            connectionError = .unknown(domain: e.domain, code: e.code)
            return false
        }
    }

    func addCustomHeader() {
        customHeaders.append(CustomHeaderEntry())
    }

    func removeCustomHeader(id: UUID) {
        customHeaders.removeAll { $0.id == id }
    }

    // MARK: - Private

    var redactedDescription: String {
        "OnboardingViewModel(username: \(username), password: [REDACTED], customHeaders: [REDACTED])"
    }

    private func headersDict() -> [String: String] {
        var dict: [String: String] = [:]
        for pair in customHeaders where !pair.key.isEmpty {
            dict[pair.key] = pair.value
        }
        return dict
    }

    private func configureJellyfinIfAvailable(
        baseURL: String,
        username: String,
        password: String,
        headers: [String: String]
    ) async {
        guard let jellyfinService,
              let url = URL(string: baseURL),
              let server = serverService.state.servers.last(where: {
                  $0.baseURL == baseURL && $0.username == username
              }) else { return }
        do {
            let capability = try await jellyfinService.probeLoginEndpoint(
                serverBaseURL: url,
                customHeaders: headers
            )
            _ = try await jellyfinService.authenticateLogin(
                server: server,
                password: password,
                customHeaders: headers
            )
            jellyfinStatus = .available(
                serverName: capability.serverName,
                version: capability.version,
                quickConnectEnabled: capability.quickConnectEnabled
            )
            jellyfinPublicUsers = capability.publicUsers
        } catch {
            // Jellyfin is optional. OpenSubsonic authentication has already succeeded, so an
            // unavailable/partial Jellyfin layer must never reject the user's server login.
        }
    }

    private func jellyfinServerDisplayName(fallback: String) -> String {
        if case let .available(serverName, _, _) = jellyfinStatus,
           let serverName, !serverName.isEmpty {
            return serverName
        }
        return URL(string: fallback)?.host ?? fallback
    }

    private func quickConnectErrorMessage(_ error: Error) -> String {
        switch error {
        case JellyfinClientError.quickConnectDisabled:
            return String(localized: "Quick Connect is disabled on this server.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case JellyfinClientError.quickConnectTimedOut:
            return String(localized: "The Quick Connect code expired. Try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case JellyfinClientError.unavailable(statusCode: 401), JellyfinClientError.unavailable(statusCode: 403), JellyfinClientError.authenticationRequired:
            return String(localized: "The server rejected the approved sign-in. Request a new code and try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case is URLError:
            return String(localized: "Could not reach your server. Check the connection and try again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case JellyfinClientError.missingAuthenticatedUser:
            return String(localized: "The server did not return an authenticated user.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        default:
            return String(localized: "Quick Connect could not be completed.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}
