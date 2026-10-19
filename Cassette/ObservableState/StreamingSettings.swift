import Foundation
import Observation

/// Server delivery method. Automatic chooses per source; explicit choices are preserved.
nonisolated enum JellyfinPlaybackRoute: String, CaseIterable, Sendable {
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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var _jellyfinRoute: JellyfinPlaybackRoute
    @ObservationIgnored private var _wifiFormat: CacheFormat
    @ObservationIgnored private var _cellularFormat: CacheFormat
    @ObservationIgnored private var _downloadFormat: CacheFormat
    @ObservationIgnored private var _preferDolbyAtmos: Bool

    /// Opt-in alternative file selection; takes effect for the next resolved song.
    var preferDolbyAtmos: Bool {
        get { access(keyPath: \.preferDolbyAtmos); return _preferDolbyAtmos }
        set {
            withMutation(keyPath: \.preferDolbyAtmos) { _preferDolbyAtmos = newValue }
            defaults.set(newValue, forKey: Self.atmosKey)
        }
    }
    private static let atmosKey = "cassette.streaming.preferDolbyAtmos"

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
            defaults.set(newValue.rawValue, forKey: Self.wifiKey)
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
            defaults.set(newValue.rawValue, forKey: Self.cellularKey)
        }
    }

    var downloadFormat: CacheFormat {
        get {
            access(keyPath: \.downloadFormat)
            return _downloadFormat
        }
        set {
            withMutation(keyPath: \.downloadFormat) { _downloadFormat = newValue }
            defaults.set(newValue.rawValue, forKey: Self.downloadKey)
        }
    }

    private static let wifiKey = "cassette.streaming.wifi"
    private static let cellularKey = "cassette.streaming.cellular"
    private static let downloadKey = "cassette.streaming.download"

    private static let routeKey = "cassette.streaming.jellyfinRoute"

    var jellyfinRoute: JellyfinPlaybackRoute {
        get {
            access(keyPath: \.jellyfinRoute)
            return _jellyfinRoute
        }
        set {
            withMutation(keyPath: \.jellyfinRoute) { _jellyfinRoute = newValue }
            adaptiveCeiling = nil
            defaults.set(newValue.rawValue, forKey: Self.routeKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _preferDolbyAtmos = defaults.bool(forKey: Self.atmosKey)
        CacheFormat.migrateLegacyStoredValues(in: defaults)
        _jellyfinRoute = JellyfinPlaybackRoute(rawValue: defaults.string(forKey: Self.routeKey) ?? "") ?? .automatic
        let wifiRaw = defaults.string(forKey: Self.wifiKey)
        let cellRaw = defaults.string(forKey: Self.cellularKey)
        _wifiFormat = CacheFormat(rawValue: wifiRaw ?? "") ?? .matchStream
        _cellularFormat = CacheFormat(rawValue: cellRaw ?? "") ?? .matchStream
        let downloadRaw = defaults.string(forKey: Self.downloadKey)
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
        preferDolbyAtmos = defaults.bool(forKey: Self.atmosKey)
        CacheFormat.migrateLegacyStoredValues(in: defaults)
        jellyfinRoute = JellyfinPlaybackRoute(rawValue: defaults.string(forKey: Self.routeKey) ?? "") ?? .automatic
        let wifiRaw = defaults.string(forKey: Self.wifiKey)
        let cellRaw = defaults.string(forKey: Self.cellularKey)
        wifiFormat = CacheFormat(rawValue: wifiRaw ?? "") ?? .matchStream
        cellularFormat = CacheFormat(rawValue: cellRaw ?? "") ?? .matchStream
        let downloadRaw = defaults.string(forKey: Self.downloadKey)
        downloadFormat = CacheFormat(rawValue: downloadRaw ?? "") ?? .matchStream
    }
}
