import Foundation

/// Only bytes fetched without a size/format transformation receive this provenance marker.
nonisolated enum OriginalArtwork {
    static func storageID(_ coverArtID: String) -> String { "\(coverArtID)@original-v1" }
    static let didInstall = Notification.Name("CassetteOriginalArtworkDidInstall")
}
