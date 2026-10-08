import Foundation
import Observation

/// How a Jellyfin-compatible server is asked for audio.
///
/// Routing vocabulary, not a setting: Settings → Audio Quality has no playback-method row any more.
/// `MediaResolver` always asks for `.automatic`, and `PlaybackDecisionPolicy` derives Direct Play vs
/// a server-side transcode from the configured quality, the current network and the source itself.
/// `.hls` and `.originalFile` stay implemented for a future manual override; nothing sets them.
nonisolated enum JellyfinPlaybackRoute: String, Sendable {
    case automatic
    case directPlay
    case universal
    case hls
    case originalFile
    case openSubsonic
}

@Observable
@MainActor
final class StreamingSettings {
    @ObservationIgnored private var _wifiFormat: CacheFormat
    @ObservationIgnored private var _cellularFormat: CacheFormat
    @ObservationIgnored private var _downloadFormat: CacheFormat

    /// Session-only, never persisted: the quality ceiling the app fell back to after the engine
    /// re-buffered on a link that could not sustain the Automatic pick. Cleared when a fresh
    /// measurement shows a fast link again, so a new launch always starts optimistic.
    var adaptiveCeiling: CacheFormat? {
        didSet { adaptiveCeilingLearnedAt = adaptiveCeiling == nil ? nil : Date() }
    }
    private var adaptiveCeilingLearnedAt: Date?
    private var adaptiveNetworkWasLimited: Bool?

    /// A stall on another connection must not pin a recovered connection to AAC indefinitely.
    func currentAdaptiveCeiling(isLimited: Bool, now: Date = Date()) -> CacheFormat? {
        defer { adaptiveNetworkWasLimited = isLimited }
        if let previous = adaptiveNetworkWasLimited, previous != isLimited {
            adaptiveCeiling = nil
        }
        if let learned = adaptiveCeilingLearnedAt, now.timeIntervalSince(learned) >= 120 {
            adaptiveCeiling = nil
        }
        return adaptiveCeiling
    }
    /// Compatibility with older recovery callers; explicit quality is no longer lowered by this flag.
    var adaptiveCeilingAppliesToExplicitChoice = false

    var wifiFormat: CacheFormat {
        get {
            access(keyPath: \.wifiFormat)
            return _wifiFormat
        }
        set {
            withMutation(keyPath: \.wifiFormat) { _wifiFormat = newValue }
            adaptiveCeiling = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.wifiKey)
        }
    }

    var cellularFormat: CacheFormat {
        get {
            access(keyPath: \.cellularFormat)
            return _cellularFormat
        }
        set {
            withMutation(keyPath: \.cellularFormat) { _cellularFormat = newValue }
            adaptiveCeiling = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.cellularKey)
        }
    }

    var downloadFormat: CacheFormat {
        get {
            access(keyPath: \.downloadFormat)
            return _downloadFormat
        }
        set {
            withMutation(keyPath: \.downloadFormat) { _downloadFormat = newValue }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.downloadKey)
        }
    }

    private static let wifiKey = "cassette.streaming.wifi"
    private static let cellularKey = "cassette.streaming.cellular"
    private static let downloadKey = "cassette.streaming.download"

    /// The playback-method menu was removed, so a route stored by an older build is dead weight:
    /// `PlaybackDecisionPolicy` decides now. Drop the key instead of letting it linger in
    /// `UserDefaults` (and survive "Reset cache and settings").
    private static func removeRetiredPlaybackRoute() {
        UserDefaults.standard.removeObject(forKey: "cassette.streaming.jellyfinRoute")
    }

    init() {
        CacheFormat.migrateLegacyStoredValues()
        Self.removeRetiredPlaybackRoute()
        let wifiRaw = UserDefaults.standard.string(forKey: Self.wifiKey)
        let cellRaw = UserDefaults.standard.string(forKey: Self.cellularKey)
        _wifiFormat = CacheFormat(rawValue: wifiRaw ?? "") ?? .matchStream
        _cellularFormat = CacheFormat(rawValue: cellRaw ?? "") ?? .matchStream
        let downloadRaw = UserDefaults.standard.string(forKey: Self.downloadKey)
        _downloadFormat = CacheFormat(rawValue: downloadRaw ?? "") ?? .matchStream
    }

    /// Stream format for the active network. A limited (metered or constrained) link uses the
    /// cellular quality so a throttled Wi-Fi connection is not silently handed the original
    /// bitstream. An explicit lossless ("Original / FLAC") selection is always honored —
    /// availability depends on the server's files.
    func formatForCurrentNetwork(isLimited: Bool) -> CacheFormat {
        isLimited ? cellularFormat : wifiFormat
    }

    func reloadFromDefaults() {
        CacheFormat.migrateLegacyStoredValues()
        let wifiRaw = UserDefaults.standard.string(forKey: Self.wifiKey)
        let cellRaw = UserDefaults.standard.string(forKey: Self.cellularKey)
        _wifiFormat = CacheFormat(rawValue: wifiRaw ?? "") ?? .matchStream
        _cellularFormat = CacheFormat(rawValue: cellRaw ?? "") ?? .matchStream
        let downloadRaw = UserDefaults.standard.string(forKey: Self.downloadKey)
        _downloadFormat = CacheFormat(rawValue: downloadRaw ?? "") ?? .matchStream
    }
}
