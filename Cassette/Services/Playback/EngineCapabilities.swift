import Foundation

/// Public-API limits, shared by transport policy and the current-playback display.
/// AVPlayer volume preserves its native decoding/output path, but cannot amplify above unity.
nonisolated struct EngineCapabilities: Sendable, Equatable {
    let native: Bool
    let wirelessRoute: Bool
    var supportsGainBoost: Bool { !native }
    var supportsSequentialFades: Bool { !wirelessRoute }
    var supportsOverlappingCrossfade: Bool { false }

    func appliedGainDB(requested: Float) -> Float {
        guard requested.isFinite else { return 0 }
        return supportsGainBoost ? requested : min(0, requested)
    }
    func nativeGainMultiplier(requested: Float) -> Float {
        pow(10, appliedGainDB(requested: requested) / 20)
    }
}

nonisolated struct PlaybackGainState: Sendable, Equatable {
    enum Status: String, Sendable {
        case disabled = "Off"
        case noMetadata = "No ReplayGain tags"
        case applied = "Applied"
        case nativeBoostUnavailable = "Positive gain unavailable on this playback path"
    }
    var enabled = false
    var hasMetadata = false
    var requestedDB: Float = 0
    func status(capabilities: EngineCapabilities) -> Status {
        guard enabled else { return .disabled }
        guard hasMetadata else { return .noMetadata }
        return !capabilities.supportsGainBoost && requestedDB > 0 ? .nativeBoostUnavailable : .applied
    }
}
