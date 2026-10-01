import Testing
@testable import Cassette

struct NavidromeJellyfinIDCodecTests {
    @Test func matchesOfficialNavidromeGoldenVector() {
        let canonical = "6VHl3uR4kss6sUPKA8Cwnk"
        let guid = "e3b7fc2ae9447bbec37a13bf916e3cf6"
        #expect(NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: canonical) == guid)
        #expect(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: guid) == canonical)
        #expect(NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: "7N42dgm5tFLK9N8MT7fHC7") == String(repeating: "f", count: 32))
    }

    @Test func canonicalIDRoundTripsThroughJellyfinGUID() {
        let canonical = "5QFKvMsJrd57QE2Le2dKKo"
        let guid = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: canonical)
        #expect(guid?.count == 32)
        #expect(guid == guid?.lowercased())
        #expect(guid.flatMap { NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: $0) } == canonical)
    }

    @Test func acceptsDashedUppercaseGUID() {
        let canonical = "5QFKvMsJrd57QE2Le2dKKo"
        let guid = NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: canonical)!
        let dashed = "\(guid.prefix(8))-\(guid.dropFirst(8).prefix(4))-\(guid.dropFirst(12).prefix(4))-\(guid.dropFirst(16).prefix(4))-\(guid.dropFirst(20))".uppercased()
        #expect(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: dashed) == canonical)
    }

    @Test func neverTreatsLegacyIDAsCanonical() {
        #expect(NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: "legacy-song-id") == nil)
        #expect(NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: "42") == nil)
    }

    @Test func playlistEntryReservedGUIDIsNotAnEntity() {
        let entry = "0000000000000000000000000300012c"
        #expect(NavidromeJellyfinIDCodec.playlistEntryID(fromJellyfinGUID: entry) == "300")
        #expect(NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: entry) == nil)
    }
}
