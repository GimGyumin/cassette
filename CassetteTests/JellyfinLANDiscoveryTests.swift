import Foundation
import Testing
@testable import Cassette

struct JellyfinLANDiscoveryTests {
    @Test func decodesOfficialDiscoveryResponse() throws {
        let data = try #require(
            #"{"Address":"http://192.168.1.12:4533","Id":"server-id","Name":"Navidrome","EndpointAddress":null}"#.data(using: .utf8)
        )
        let server = try #require(JellyfinLANDiscoveryService.decodeResponse(data))
        #expect(server.address == "http://192.168.1.12:4533")
        #expect(server.id == "server-id")
        #expect(server.name == "Navidrome")
    }

    @Test func rejectsMalformedDiscoveryResponse() {
        #expect(JellyfinLANDiscoveryService.decodeResponse(Data("not-json".utf8)) == nil)
    }

    // MARK: - Subnet sweep

    @Test func sweepsEveryHostOfASlash24Subnet() {
        let hosts = JellyfinLANDiscoveryService.hostAddresses(
            ipv4: "192.168.0.42",
            netmask: "255.255.255.0"
        )
        #expect(hosts.count == 254)
        #expect(hosts.first == "192.168.0.1")
        #expect(hosts.last == "192.168.0.254")
        // The network and broadcast addresses are not hosts.
        #expect(!hosts.contains("192.168.0.0"))
        #expect(!hosts.contains("192.168.0.255"))
    }

    @Test func sweepIsBoundedForWideSubnets() {
        // A /16 has 65k hosts; the sweep must stay bounded instead of enumerating all of them.
        let hosts = JellyfinLANDiscoveryService.hostAddresses(
            ipv4: "10.0.5.7",
            netmask: "255.255.0.0"
        )
        #expect(hosts.count == JellyfinLANDiscoveryService.maximumHostScan)
        #expect(hosts.first == "10.0.0.1")
    }

    @Test func handlesSlash30AndRejectsUnusableMasks() {
        // /30 → two usable hosts.
        #expect(
            JellyfinLANDiscoveryService.hostAddresses(ipv4: "192.168.1.5", netmask: "255.255.255.252")
                == ["192.168.1.5", "192.168.1.6"]
        )
        // /32 (single host) and a zero mask have no sweepable hosts.
        #expect(JellyfinLANDiscoveryService.hostAddresses(ipv4: "192.168.1.5", netmask: "255.255.255.255").isEmpty)
        #expect(JellyfinLANDiscoveryService.hostAddresses(ipv4: "192.168.1.5", netmask: "0.0.0.0").isEmpty)
        #expect(JellyfinLANDiscoveryService.hostAddresses(ipv4: "not-an-ip", netmask: "255.255.255.0").isEmpty)
    }

    @Test func ipv4ConversionRoundTrips() {
        #expect(JellyfinLANDiscoveryService.ipv4Value("192.168.1.20") == 0xC0A80114)
        #expect(JellyfinLANDiscoveryService.ipv4String(0xC0A80114) == "192.168.1.20")
        #expect(JellyfinLANDiscoveryService.ipv4Value("999.1.1.1") == nil)
    }

    @Test func probeTargetsAlwaysIncludeTheBroadcast() {
        // The unicast sweep is the entitlement-free path; the broadcast stays as a best effort.
        #expect(JellyfinLANDiscoveryService.probeTargets().contains("255.255.255.255"))
    }
}
