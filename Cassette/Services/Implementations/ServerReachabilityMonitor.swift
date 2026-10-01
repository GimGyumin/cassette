// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
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
/// 3. re-pings every `recoveryInterval` while unreachable, so those tabs come back within seconds of
///    the server answering again,
/// 4. keeps one cheap check every `healthyInterval` while reachable, so a server that dies
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

    private var loop: Task<Void, Never>?
    private var isProbing = false
    /// Set while the device itself has no route, so the first tick after connectivity returns probes
    /// immediately instead of waiting out `healthyInterval`.
    private var wasOffline = false
    private var lastProbeAt = Date.distantPast

    /// False while the app is in the background. iOS suspends the process anyway, and the flag keeps
    /// a resume from firing a burst of probes.
    var isAppActive = true

    init(
        serverState: ServerState,
        probe: @escaping () async throws -> Void,
        onRecovered: (() async -> Void)? = nil,
        healthyInterval: TimeInterval = 20,
        recoveryInterval: TimeInterval = 3
    ) {
        self.serverState = serverState
        self.probe = probe
        self.onRecovered = onRecovered
        self.healthyInterval = healthyInterval
        self.recoveryInterval = recoveryInterval
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
        Logger.network.debug("ServerReachabilityMonitor started.")
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One probe right now: app became active, the network path changed, or the user tapped
    /// "Try Again" on the offline state.
    func checkNow() async {
        guard serverState.isOnline else {
            setReachable(false, reason: "device has no network route")
            return
        }
        await probeOnce()
    }

    // MARK: - Private

    private func run() async {
        // A 500 ms tick so losing the device's route is reflected on the spot — that is the case
        // users notice first — while the ping itself stays on its own (much slower) interval.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard isAppActive else { continue }

            guard serverState.isOnline else {
                wasOffline = true
                setReachable(false, reason: "device has no network route")
                continue
            }

            if wasOffline {
                wasOffline = false
                lastProbeAt = .distantPast
            }

            let interval = serverState.isServerReachable ? healthyInterval : recoveryInterval
            guard Date().timeIntervalSince(lastProbeAt) >= interval else { continue }
            lastProbeAt = Date()
            await probeOnce()
        }
    }

    private func probeOnce() async {
        guard !isProbing else { return }
        guard serverState.activeServer != nil else {
            // No account yet: onboarding owns the UI, and there is nothing to reach.
            setReachable(true, reason: "no active server")
            return
        }
        isProbing = true
        defer { isProbing = false }

        do {
            try await probe()
            setReachable(true, reason: "ping succeeded")
        } catch {
            setReachable(false, reason: "ping failed: \(error.localizedDescription)")
        }
    }

    private func setReachable(_ reachable: Bool, reason: String) {
        guard serverState.isServerReachable != reachable else { return }
        serverState.isServerReachable = reachable
        lastProbeAt = Date()
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
