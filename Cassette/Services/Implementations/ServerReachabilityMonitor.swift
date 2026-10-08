// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import OSLog

/// Tracks whether the **active server** answers — a different question from `ServerState.isOnline`.
///
/// `NetworkMonitor` only knows whether the device has a usable route: a Wi-Fi link whose upstream is
/// down still reports `satisfied`, and a server that is restarting (or was moved) answers nothing
/// while the device is perfectly online. Home / Discover / the browse tabs must show a "cannot reach
/// the server" state in that case, and they must recover **without** the user reopening the app, so
/// this monitor:
///
/// 1. declares the server unreachable the instant the device has no route at all,
/// 2. confirms the outage with one bounded ping (the shared client builds with `retryPolicy: .none`)
///    before any content is hidden,
/// 3. retries outages with bounded backoff, and probes immediately when the network returns,
/// 4. keeps one check every `healthyInterval` while reachable, so a server that dies
///    mid-session is noticed without waiting for the next page load to fail.
///
/// The probe and the recovery hook are injected (`serverService.testConnection()` and
/// `playerService.handleNetworkRestored()` in production) so the monitor stays independent of
/// SwiftSonic and testable. Every transition is published on `ServerState`.
@MainActor
final class ServerReachabilityMonitor {
    private let serverState: ServerState
    private let probe: () async throws -> Void
    private let onRecovered: (() async -> Void)?
    private let healthyInterval: TimeInterval
    private let recoveryInterval: TimeInterval

    private var scheduledCheck: Task<Void, Never>?
    private var activeProbe: Task<Void, Never>?
    private var isStarted = false
    private var generation = 0
    private var observationGeneration = 0
    private var consecutiveFailures = 0
    private struct Inputs: Equatable {
        let online: Bool
        let serverID: UUID?
        let baseURL: String?
        let username: String?
    }
    private var observedInputs: Inputs?
    private var inputs: Inputs {
        Inputs(online: serverState.isOnline, serverID: serverState.activeServer?.id,
               baseURL: serverState.activeServer?.baseURL, username: serverState.activeServer?.username)
    }

    /// False while the app is in the background. iOS suspends the process anyway, and the flag keeps
    /// a resume from firing a burst of probes.
    var isAppActive = true {
        didSet {
            if oldValue != isAppActive, isStarted { reconcileInputs(force: true) }
        }
    }

    init(
        serverState: ServerState,
        probe: @escaping () async throws -> Void,
        onRecovered: (() async -> Void)? = nil,
        healthyInterval: TimeInterval = 60,
        recoveryInterval: TimeInterval = 3
    ) {
        self.serverState = serverState
        self.probe = probe
        self.onRecovered = onRecovered
        self.healthyInterval = healthyInterval
        self.recoveryInterval = recoveryInterval
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observationGeneration += 1
        observeInputs()
        reconcileInputs(force: true)
        Logger.network.debug("ServerReachabilityMonitor started.")
    }

    func stop() {
        isStarted = false
        observationGeneration += 1
        cancelChecks()
    }

    /// One probe right now: app became active, the network path changed, or the user tapped
    /// "Try Again" on the offline state.
    func checkNow() async {
        guard isAppActive else { return }
        guard serverState.activeServer != nil else {
            setReachable(true, reason: "no active server")
            return
        }
        guard serverState.isOnline else {
            setReachable(false, reason: "device has no network route")
            return
        }
        scheduledCheck?.cancel()
        scheduledCheck = nil
        if let activeProbe {
            await activeProbe.value
            return
        }
        let generation = self.generation
        let expectedInputs = inputs
        let task = Task { [weak self] in
            guard let self else { return }
            await self.probeOnce(expectedInputs: expectedInputs, generation: generation)
        }
        activeProbe = task
        await task.value
        guard generation == self.generation else { return }
        activeProbe = nil
        let delay = serverState.isServerReachable ? healthyInterval : Self.retryDelay(
            failures: consecutiveFailures, initial: recoveryInterval
        )
        scheduleCheck(after: delay)
    }

    // MARK: - Private

    private func observeInputs() {
        let observation = observationGeneration
        withObservationTracking {
            _ = inputs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted, observation == self.observationGeneration else { return }
                self.observeInputs()
                self.reconcileInputs()
            }
        }
    }

    private func cancelChecks() {
        generation += 1
        scheduledCheck?.cancel()
        scheduledCheck = nil
        activeProbe?.cancel()
        activeProbe = nil
    }

    private func reconcileInputs(force: Bool = false) {
        let current = inputs
        guard force || current != observedInputs else { return }
        observedInputs = current
        cancelChecks()
        consecutiveFailures = 0
        guard current.serverID != nil else {
            setReachable(true, reason: "no active server")
            return
        }
        guard current.online else {
            setReachable(false, reason: "device has no network route")
            return
        }
        scheduleCheck(after: 0)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        guard isStarted, isAppActive, serverState.isOnline, serverState.activeServer != nil else { return }
        scheduledCheck?.cancel()
        scheduledCheck = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(min(1, delay / 10))) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.scheduledCheck = nil
            await self?.checkNow()
        }
    }

    nonisolated static func retryDelay(failures: Int, initial: TimeInterval) -> TimeInterval {
        min(30, max(0.01, initial) * pow(2, Double(max(0, min(failures - 1, 10)))))
    }

    private func probeOnce(expectedInputs: Inputs, generation: Int) async {
        guard generation == self.generation, inputs == expectedInputs, isAppActive, !Task.isCancelled else { return }

        do {
            try await probe()
            guard generation == self.generation, inputs == expectedInputs, isAppActive, !Task.isCancelled else { return }
            consecutiveFailures = 0
            setReachable(true, reason: "ping succeeded")
        } catch {
            guard generation == self.generation, inputs == expectedInputs, isAppActive, !Task.isCancelled else { return }
            consecutiveFailures += 1
            setReachable(false, reason: "ping failed: \(error.localizedDescription)")
        }
    }

    private func setReachable(_ reachable: Bool, reason: String) {
        guard serverState.isServerReachable != reachable else { return }
        serverState.isServerReachable = reachable
        if reachable {
            Logger.network.info(
                "Active server answered again (\(reason, privacy: .public)) — server-backed tabs restored"
            )
            if let onRecovered {
                Task { await onRecovered() }
            }
        } else {
            Logger.network.warning(
                "Active server unreachable (\(reason, privacy: .public)) — server-backed tabs show the offline state"
            )
        }
    }
}
