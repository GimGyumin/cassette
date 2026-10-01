import Foundation

/// Checked on the same executor as MPNowPlayingInfoCenter, including after image I/O.
@MainActor
final class NowPlayingArtworkRevision {
    private var value = 0
    nonisolated init() {}

    func accept(_ revision: Int) -> Bool {
        guard revision >= value else { return false }
        value = revision
        return true
    }

    func matches(_ revision: Int) -> Bool { revision == value }
}
