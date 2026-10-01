// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

// MARK: - Mock service

@MainActor
final class MockServerService: ServerServiceProtocol {
    let state: ServerState = ServerState()

    // Configurable outcomes
    var testConnectionError: (any Error)? = nil
    var addServerError: (any Error)? = nil
    var addServerCalled = false
    var activatesAddedServer = true
    var lastTestedURL: String?
    var lastAddedBaseURL: String?

    func testConnection(
        url: String, username: String, password: String,
        customHeaders: [String: String]
    ) async throws {
        lastTestedURL = url
        if let error = testConnectionError { throw error }
    }

    func addServer(
        displayName: String, baseURL: String, username: String,
        password: String, customHeaders: [String: String]
    ) async throws {
        addServerCalled = true
        lastAddedBaseURL = baseURL
        if let error = addServerError { throw error }
        if activatesAddedServer {
            let config = ServerConfig(displayName: displayName, baseURL: baseURL,
                                      username: username, isActive: true)
            let snapshot = ServerSnapshot(from: config)
            state.servers.append(snapshot)
            state.activeServer = snapshot
        }
    }

    func addServerWithJellyfinToken(
        displayName: String,
        baseURL: String,
        username: String,
        jellyfinAccessToken: String,
        customHeaders: [String: String]
    ) async throws {
        try await addServer(
            displayName: displayName,
            baseURL: baseURL,
            username: username,
            password: "",
            customHeaders: customHeaders
        )
    }

    // Unused stubs
    func removeServer(id: UUID) async throws {}
    func setActiveServer(id: UUID) async throws {}
    func updateCustomHeaders(_ headers: [String: String], forServer id: UUID) async throws {}
    func updateServer(id: UUID, displayName: String, baseURL: String, username: String, password: String, customHeaders: [String: String]) async throws {}
    func testConnection() async throws {}
    func loadPersistedState() async {}
    func preWarmClient() async {}
    func makeSwiftSonicClient() async throws -> SwiftSonicClient { throw CassetteError.notImplemented }
    func activeCredentials() async throws -> ServerCredentials { throw CassetteError.notImplemented }
}

// MARK: - Suite

@Suite("OnboardingViewModel — testConnection error routing")
@MainActor
struct OnboardingViewModelTests {

    private func makeViewModel() -> OnboardingViewModel {
        makeViewModel(service: MockServerService())
    }

    private func makeViewModel(service: MockServerService) -> OnboardingViewModel {
        let vm = OnboardingViewModel(serverService: service)
        vm.serverURL = "https://music.example.com"
        vm.username = "admin"
        vm.password = "secret"
        return vm
    }

    @Test func bareAddressUsesHTTPSForProbeAndSavedAccount() async {
        let service = MockServerService()
        let vm = makeViewModel(service: service)
        vm.serverURL = "music.example.com:8443/jellyfin"
        #expect(vm.hasEnteredServerURL)
        #expect(!vm.isHTTP)
        await vm.testConnection()
        #expect(service.lastTestedURL == "https://music.example.com:8443")
        #expect(await vm.addServer())
        #expect(service.lastAddedBaseURL == "https://music.example.com:8443")
        vm.serverURL = " HTTP://music.local:8096 "
        #expect(vm.isHTTP)
    }

    @Test func quickConnectOnlyAppearsWhenServerEnablesIt() {
        let vm = makeViewModel()
        for status: JellyfinLoginStatus in [.idle, .checking, .unavailable,
                                            .available(serverName: nil, version: nil, quickConnectEnabled: false)] {
            vm.jellyfinStatus = status
            #expect(!vm.supportsQuickConnect)
        }
        vm.jellyfinStatus = .available(serverName: "Music", version: "1", quickConnectEnabled: true)
        #expect(vm.supportsQuickConnect)
    }

    // MARK: testConnection

    @Test func testConnection_success_clearsConnectionError() async {
        let vm = makeViewModel()
        await vm.testConnection()
        #expect(vm.connectionError == nil)
        #expect(vm.isLoading == false)
    }

    @Test func testConnection_cannotConnect_setsCannotConnectError() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.cannotConnect
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        #expect(vm.connectionError == .cannotConnect)
    }

    @Test func testConnection_authFailed_setsUnauthorizedError() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.unauthorized
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        #expect(vm.connectionError == .unauthorized)
    }

    @Test func testConnection_subsonicError_setsSubsonicError() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.subsonicError(code: .generic, message: "Quota exceeded")
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        #expect(vm.connectionError == .subsonicError(code: .generic, message: "Quota exceeded"))
    }

    @Test func testConnection_invalidURL_setsInvalidURLError() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.invalidURL
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        #expect(vm.connectionError == .invalidURL)
    }

    @Test func testConnection_unknownError_wrapsAsUnknown() async {
        let service = MockServerService()
        service.testConnectionError = CassetteError.notImplemented
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        if case .unknown = vm.connectionError { } else {
            Issue.record("Expected .unknown, got \(String(describing: vm.connectionError))")
        }
    }

    @Test func testConnection_isLoadingFalseAfterCompletion() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.cannotConnect
        let vm = makeViewModel(service: service)

        await vm.testConnection()

        #expect(vm.isLoading == false)
    }

    // MARK: addServer

    @Test func addServer_success_noConnectionError() async {
        let service = MockServerService()
        let vm = makeViewModel(service: service)

        let succeeded = await vm.addServer()

        #expect(succeeded)
        #expect(vm.connectionError == nil)
        #expect(service.addServerCalled)
    }

    @Test func jellyfinAddressIsNormalizedForConnectionAndStorage() async {
        let service = MockServerService()
        let vm = makeViewModel(service: service)
        vm.serverURL = "https://music.example.com/jellyfin/"

        let succeeded = await vm.addServer()

        #expect(succeeded)
        #expect(service.lastTestedURL == "https://music.example.com")
        #expect(service.lastAddedBaseURL == "https://music.example.com")
    }

    @Test func duplicateSubmitCannotAdvanceOnboarding() async {
        let service = MockServerService()
        let vm = makeViewModel(service: service)
        vm.isLoading = true
        let succeeded = await vm.addServer()
        #expect(!succeeded)
        #expect(!service.addServerCalled)
        #expect(vm.isLoading)
    }

    @Test func persistedButInactiveServerCannotAdvanceOnboarding() async {
        let service = MockServerService()
        service.activatesAddedServer = false
        let vm = makeViewModel(service: service)
        let succeeded = await vm.addServer()
        #expect(!succeeded)
        #expect(vm.connectionError != nil)
        #expect(!vm.isLoading)
    }

    @Test func invalidFormCannotAdvanceOnboarding() async {
        let service = MockServerService()
        let vm = makeViewModel(service: service)
        vm.password = ""
        let succeeded = await vm.addServer()
        #expect(!succeeded)
        #expect(!service.addServerCalled)
    }

    @Test func addServer_connectionFails_doesNotCallAddServer() async {
        let service = MockServerService()
        service.testConnectionError = ConnectionTestError.cannotConnect
        let vm = makeViewModel(service: service)

        await vm.addServer()

        #expect(vm.connectionError == .cannotConnect)
        #expect(!service.addServerCalled)
    }

    @Test func addServer_persistFails_setsUnknownError() async {
        let service = MockServerService()
        service.addServerError = CassetteError.keychainWriteFailed(-1)
        let vm = makeViewModel(service: service)

        await vm.addServer()

        if case .unknown = vm.connectionError { } else {
            Issue.record("Expected .unknown after persist failure, got \(String(describing: vm.connectionError))")
        }
        #expect(service.addServerCalled)
    }
}
