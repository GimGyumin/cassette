import Foundation
import Testing
@testable import Cassette

@Suite("Event-driven server reachability")
@MainActor
struct ServerReachabilityMonitorTests {
    private func state() -> ServerState {
        let state = ServerState()
        state.activeServer = server("first")
        return state
    }

    private func server(_ name: String) -> ServerSnapshot {
        ServerSnapshot(from: ServerConfig(displayName: name, baseURL: "https://\(name).example", username: "test"))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test("Offline and recovery react to state changes without periodic polling")
    func observesNetworkChanges() async throws {
        let state = state()
        var calls = 0
        let monitor = ServerReachabilityMonitor(serverState: state, probe: { calls += 1 })
        monitor.start()
        defer { monitor.stop() }
        try await eventually { calls == 1 }
        state.isOnline = false
        try await eventually { !state.isServerReachable }
        #expect(calls == 1)
        state.isOnline = true
        try await eventually { calls == 2 && state.isServerReachable }
    }

    @Test("Concurrent foreground checks share a single request")
    func coalescesChecks() async throws {
        let state = state()
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let monitor = ServerReachabilityMonitor(serverState: state, probe: {
            calls += 1
            await withCheckedContinuation { release = $0 }
        })
        let first = Task { await monitor.checkNow() }
        try await eventually { release != nil }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await monitor.checkNow()
        }
        try await eventually { secondStarted }
        release?.resume()
        await first.value
        await second.value
        #expect(calls == 1)
        monitor.stop()
    }

    @Test("Cancelled old-account requests cannot mark the new account offline")
    func discardsOldAccountResult() async throws {
        let state = state()
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let monitor = ServerReachabilityMonitor(serverState: state, probe: {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { release = $0 }
                throw URLError(.timedOut)
            }
        })
        monitor.start()
        defer { monitor.stop() }
        try await eventually { release != nil }
        state.activeServer = server("second")
        try await eventually { calls == 2 }
        release?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(state.isServerReachable)
        #expect(calls == 2)
    }

    @Test("Background cancels probing without publishing a false outage")
    func backgroundStopsWork() async throws {
        let state = state()
        var calls = 0
        let monitor = ServerReachabilityMonitor(serverState: state, probe: {
            calls += 1
            try await Task.sleep(for: .seconds(10))
        })
        monitor.start()
        defer { monitor.stop() }
        try await eventually { calls == 1 }
        monitor.isAppActive = false
        await monitor.checkNow()
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == 1)
        #expect(state.isServerReachable)
        monitor.isAppActive = true
        try await eventually { calls == 2 }
    }

    @Test("No account and stopped monitors perform no requests")
    func noAccountAndStop() async throws {
        let state = ServerState()
        var calls = 0
        let monitor = ServerReachabilityMonitor(serverState: state, probe: { calls += 1 })
        monitor.start()
        await monitor.checkNow()
        #expect(calls == 0)
        monitor.stop()
        state.activeServer = server("second")
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == 0)
        monitor.start()
        defer { monitor.stop() }
        try await eventually { calls == 1 }
    }

    @Test("Outages back off to a bounded recovery interval")
    func backoff() {
        #expect((1...6).map { ServerReachabilityMonitor.retryDelay(failures: $0, initial: 3) }
                == [3, 6, 12, 24, 30, 30])
        #expect(ServerReachabilityMonitor.retryDelay(failures: 1000, initial: 3) == 30)
    }
}
