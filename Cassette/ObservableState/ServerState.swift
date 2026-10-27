// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation

/// Sendable value-type snapshot of a ServerConfig for crossing actor boundaries safely.
nonisolated struct ServerSnapshot: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let baseURL: String
    let username: String
    let serverVersion: String?

    init(from config: ServerConfig) {
        self.id = config.id
        self.displayName = config.displayName
        self.baseURL = config.baseURL
        self.username = config.username
        self.serverVersion = config.serverVersion
    }
}

/// Observable UI state for server connectivity. Updated by ServerService via MainActor.run.
@Observable
@MainActor
final class ServerState {
    var servers: [ServerSnapshot] = []
    @ObservationIgnored private(set) var accountRevision: UInt64 = 0
    var activeServer: ServerSnapshot? {
        didSet { if oldValue != activeServer { accountRevision &+= 1 } }
    }
    var isConnected: Bool = false
    /// False when the **active server** cannot be reached: a ping timed out, the host refused the
    /// connection, or the device has no route at all. Driven by `ServerReachabilityMonitor`, which
    /// also clears it again within seconds of the server answering.
    ///
    /// Deliberately separate from `isOnline`: a Wi-Fi link whose upstream is down still reports
    /// "online" to `NWPathMonitor`, and a server that is restarting answers nothing while the device
    /// is perfectly connected. Server-backed tabs read this one; Library, Downloads and Search keep
    /// working from the local index and the download store regardless of its value.
    var isServerReachable: Bool = true
    /// Updated by NetworkMonitor. False when NWPathMonitor reports no connectivity.
    var isOnline: Bool = true
    /// Updated by NetworkMonitor. True when the connection is metered (cellular, hotspot).
    /// Default false — optimistic until the first NWPath update corrects it on launch (~100ms).
    var isExpensive: Bool = false
    /// Transport type, separate from cost: a Wi-Fi hotspot may also be expensive.
    var isCellularConnection: Bool = false
    /// Updated by NetworkMonitor. True when the path is constrained — iOS Low Data Mode, or a
    /// link the user marked as metered even though it is Wi-Fi. Unlike `isExpensive` this also
    /// covers throttled Wi-Fi, which is why background transfers key off it.
    var isNetworkConstrained: Bool = false
    /// One coherent path snapshot, including changes that leave `isOnline` true.
    var playbackNetworkPath: PlaybackNetworkPath?
    /// Last measured throughput (bytes/s), published by `MediaResolver` after `NetworkSpeedProbe`
    /// samples the link. Lets a *throttled* Wi-Fi link — which iOS reports as unlimited — stop
    /// background transfers and adapt Automatic quality, the way cellular already does.
    var measuredBytesPerSecond: Double?
    /// Single source of truth for "may this app spend bandwidth in the background?".
    ///
    /// Metered, constrained **or measured-slow** counts as limited. Cache writes, gapless
    /// pre-buffering, crossfade prefetch, automatic downloads, speculative artwork and cover
    /// preloading all read this instead of `isExpensive` so a slow link cannot be mistaken for an
    /// unmetered one and starve the live stream.
    var isLimitedNetwork: Bool {
        NetworkCostPolicy.isLimited(
            isExpensive: isExpensive,
            isConstrained: isNetworkConstrained,
            measuredBytesPerSecond: measuredBytesPerSecond
        )
    }
    // Prevents OnboardingView flash before persisted state is restored on launch.
    var isLoadingPersistedState: Bool = true
    /// Blocks sign-in while the previous account's local data is being removed.
    var isSigningOut = false {
        didSet { if oldValue != isSigningOut { accountRevision &+= 1 } }
    }
    /// True when an active server exists but its Keychain password is missing.
    var needsCredentialReentry: Bool = false
    /// Quick Connect works, but native Subsonic requires password verification.
    var needsSubsonicVerification: Bool = false
    func requestIdentity(for serverID: UUID) throws -> ServerRequestIdentity {
        guard activeServer?.id == serverID, !isSigningOut else { throw CancellationError() }
        return ServerRequestIdentity(serverID: serverID, revision: accountRevision)
    }

    func requestIsCurrent(_ identity: ServerRequestIdentity) -> Bool {
        !isSigningOut && activeServer?.id == identity.serverID && accountRevision == identity.revision
    }

}
