import Foundation
import Testing
@testable import Cassette

struct ServerEndpointNormalizerTests {
    @Test func acceptsServerRoot() {
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "https://music.example.com") == "https://music.example.com")
    }

    @Test func stripsJellyfinSuffixForOpenSubsonic() {
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "https://music.example.com/jellyfin") == "https://music.example.com")
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "https://host.example/navidrome/jellyfin/") == "https://host.example/navidrome")
    }

    @Test func removesQueryAndFragment() {
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "https://host.example/jellyfin/?x=1#login") == "https://host.example")
    }

    @Test func defaultsBareAddressesToHTTPS() {
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: " music.example.com/jellyfin ") == "https://music.example.com")
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "music.example.com:8443/Music") == "https://music.example.com:8443/Music")
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "192.168.1.2:8096") == "https://192.168.1.2:8096")
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "[::1]:8096") == "https://[::1]:8096")
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: " HTTP://music.local:8096 ") == "http://music.local:8096")
    }

    @Test func rejectsInvalidAddress() {
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: " ") == nil)
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "not a server") == nil)
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "https://user:password@music.example.com") == nil)
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "music.example.com:65536") == nil)
        #expect(ServerEndpointNormalizer.normalizedOpenSubsonicAddress(from: "ftp://music.example.com/jellyfin") == nil)
    }
}
