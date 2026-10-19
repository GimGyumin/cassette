import Foundation

/// Only bytes fetched without a size/format transformation receive this provenance marker.
nonisolated enum OriginalArtwork {
    static func storageID(_ coverArtID: String) -> String { "\(coverArtID)@original-v1" }
    static let didInstall = Notification.Name("CassetteOriginalArtworkDidInstall")
}

/// Navidrome's content-versioned IDs carry a 16-digit image hash. Entity IDs can
/// differ for identical album/track bytes. Older timestamp suffixes are NOT hashes.
/// https://github.com/navidrome/navidrome/blob/master/model/artwork_id.go
nonisolated enum ArtworkIdentity {
    static func key(_ id: String) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, ["al-", "mf-", "dc-"].contains(where: { parts[0].hasPrefix($0) }),
              parts[0].count > 3, parts[1].count == 16,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return id }
        return "navidrome-image-" + parts[1]
    }

    static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap {
            let id = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(key(id)).inserted ? id : nil
        }
    }
}
