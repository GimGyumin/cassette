import Foundation

extension PlayerService {
    func playbackDetails() async -> PlaybackDetails? {
        guard let currentSource else { return nil }
        return PlaybackDetails(source: currentSource, usesSystemPlayer: systemPlayback.isActive)
    }
}
