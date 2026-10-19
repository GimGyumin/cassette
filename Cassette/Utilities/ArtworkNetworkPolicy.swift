import Foundation

/// Artwork can use saved bytes on any connection; new bytes must not use cellular.
/// URLSession also enforces this if the route changes after the path check.
nonisolated enum ArtworkNetworkPolicy {
    static func allowsDownload(isOnline: Bool, isCellular: Bool) -> Bool {
        isOnline && !isCellular
    }

    static func configure(_ configuration: URLSessionConfiguration) {
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = true
    }

    static func apply(to request: inout URLRequest) {
        request.allowsCellularAccess = false
        request.allowsExpensiveNetworkAccess = true
    }
}
