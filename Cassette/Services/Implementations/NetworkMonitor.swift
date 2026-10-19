// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Network
import OSLog

/// Wraps NWPathMonitor and keeps ServerState.isOnline in sync.
/// Start once from AppContainer; safe to call from any context.
final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.cassette.network", qos: .utility)

    func start(serverState: ServerState) {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            // `isConstrained` is iOS Low Data Mode (and a Wi-Fi link the user marked as
            // metered). It is not covered by `isExpensive`, so a throttled Wi-Fi link would
            // otherwise inherit every unmetered path and compete with the live stream.
            let constrained = path.isConstrained
            Task { @MainActor in
                serverState.isOnline = online
                serverState.isExpensive = expensive
                serverState.isCellularConnection = cellular
                serverState.isNetworkConstrained = constrained
            }
        }
        monitor.start(queue: queue)
        Logger.network.debug("NetworkMonitor started.")
    }

    func stop() {
        monitor.cancel()
    }
}
