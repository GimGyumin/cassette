// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Darwin
import Foundation

nonisolated struct JellyfinDiscoveredServer: Codable, Sendable, Equatable, Identifiable {
    let address: String
    let id: String
    let name: String
    let endpointAddress: String?

    enum CodingKeys: String, CodingKey {
        case address = "Address"
        case id = "Id"
        case name = "Name"
        case endpointAddress = "EndpointAddress"
    }
}

nonisolated enum JellyfinLANDiscoveryError: Error, Sendable, Equatable {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case sendFailed(Int32)
    /// Every probe was refused by the system — almost always the Local Network permission.
    case permissionDenied
}

/// Bounded Jellyfin/Navidrome discovery using the official UDP 7359 protocol.
/// The sign-in screen starts one scan; retries are explicit.
///
/// iOS refuses a send to the broadcast address (`255.255.255.255`) unless the app holds Apple's
/// Multicast Networking entitlement, and that refusal used to surface as "discovery is
/// unavailable" even after the user granted Local Network access. Discovery therefore probes the
/// **unicast** address of every host on the device's own subnets — allowed with Local Network
/// permission alone — and keeps the broadcast as a best-effort extra. One accepted datagram is
/// enough to continue; only a blanket refusal is reported as a permission problem.
nonisolated final class JellyfinLANDiscoveryService: @unchecked Sendable {
    private static let port: UInt16 = 7359
    private static let question = Data("Who is JellyfinServer?".utf8)
    /// Per-interface cap for the unicast sweep. Home networks are /24; a wider mask still gets a
    /// bounded probe plus its directed broadcast rather than thousands of packets.
    static let maximumHostScan = 512

    func discover(timeout: TimeInterval = 2.5) async throws -> [JellyfinDiscoveredServer] {
        try await Task.detached(priority: .userInitiated) {
            try Self.discoverBlocking(timeout: max(0.5, timeout))
        }.value
    }

    static func decodeResponse(_ data: Data) -> JellyfinDiscoveredServer? {
        try? JSONDecoder().decode(JellyfinDiscoveredServer.self, from: data)
    }

    // MARK: - Probe targets

    /// Addresses one discovery round should ask: the global broadcast (best effort) plus the
    /// directed host sweep of every usable IPv4 interface.
    static func probeTargets() -> [String] {
        var targets: [String] = ["255.255.255.255"]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return targets }
        defer { freeifaddrs(interfaces) }

        var pointer = interfaces
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = current.pointee.ifa_netmask else { continue }
            targets.append(contentsOf: hostAddresses(
                ipv4: ipv4String(from: address),
                netmask: ipv4String(from: netmask)
            ))
        }
        return Array(Set(targets))
    }

    /// Unicast host addresses inside an IPv4 subnet, excluding the network and broadcast addresses.
    /// Kept pure (and unit-tested) because the subnet maths is the part that silently misses hosts.
    static func hostAddresses(ipv4: String, netmask: String) -> [String] {
        guard let addressValue = ipv4Value(ipv4),
              let maskValue = ipv4Value(netmask),
              maskValue != 0, maskValue != .max else { return [] }
        let network = addressValue & maskValue
        let broadcast = network | ~maskValue
        guard broadcast > network else { return [] }
        let hostCount = Int(broadcast - network) - 1
        guard hostCount > 0 else { return [] }
        return (1...min(hostCount, maximumHostScan)).map { ipv4String(network &+ UInt32($0)) }
    }

    static func ipv4Value(_ string: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private static func ipv4String(from sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> String {
        var address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }

    private static func discoverBlocking(timeout: TimeInterval) throws -> [JellyfinDiscoveredServer] {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw JellyfinLANDiscoveryError.socketCreationFailed(errno) }
        defer { Darwin.close(descriptor) }

        var enabled: Int32 = 1
        let broadcastResult = withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_BROADCAST,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard broadcastResult == 0 else {
            throw JellyfinLANDiscoveryError.socketConfigurationFailed(errno)
        }

        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = withUnsafePointer(to: &receiveTimeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var sentAny = false
        var firstFailure: Int32?
        let targets = probeTargets()
        for target in targets {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = in_port_t(port).bigEndian
            destination.sin_addr = in_addr(s_addr: inet_addr(target))

            let sent = question.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(
                            descriptor,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            if sent == question.count {
                sentAny = true
            } else if firstFailure == nil {
                firstFailure = errno
            }
        }

        // One accepted datagram is enough: the broadcast being refused (missing Multicast
        // entitlement) must not fail a discovery the unicast sweep can still complete.
        guard sentAny else {
            let code = firstFailure ?? errno
            // No unicast target existed, so only the broadcast was attempted. That refusal is the
            // missing entitlement, not something the user can fix in Settings — keep it generic
            // rather than sending them to a permission screen that is already on.
            if targets.count == 1 {
                throw JellyfinLANDiscoveryError.sendFailed(code)
            }
            if code == EPERM || code == EACCES || code == ENETUNREACH {
                throw JellyfinLANDiscoveryError.permissionDenied
            }
            throw JellyfinLANDiscoveryError.sendFailed(code)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var serversByIdentity: [String: JellyfinDiscoveredServer] = [:]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline, !Task.isCancelled {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recvfrom(descriptor, $0.baseAddress, $0.count, 0, nil, nil)
            }
            if count > 0 {
                let payload = Data(buffer.prefix(Int(count)))
                if let server = decodeResponse(payload),
                   ServerEndpointNormalizer.openSubsonicBaseURL(from: server.address) != nil {
                    let key = server.id.isEmpty ? server.address.lowercased() : server.id
                    serversByIdentity[key] = server
                }
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }

        return serversByIdentity.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
