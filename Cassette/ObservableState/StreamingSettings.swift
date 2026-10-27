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
    @ObservationIgnored private var _allowDolbyAtmosOverCellular: Bool
    @ObservationIgnored private var _preferDolbyAtmos: Bool
    @ObservationIgnored private var _preferDolbyAtmosDownload: Bool
    @ObservationIgnored private var _losslessAudioEnabled: Bool

    nonisolated static let losslessAudioKey = "cassette.streaming.losslessAudioEnabled"

    /// Keep each network's saved quality when temporarily disabling lossless delivery.
    var losslessAudioEnabled: Bool {
        get { access(keyPath: \.losslessAudioEnabled); return _losslessAudioEnabled }
        set {
            guard _losslessAudioEnabled != newValue else { return }
            withMutation(keyPath: \.losslessAudioEnabled) { _losslessAudioEnabled = newValue }
            adaptiveCeiling = nil
            defaults.set(newValue, forKey: Self.losslessAudioKey)
        }
    }

    nonisolated static func effectiveFormat(_ format: CacheFormat, losslessEnabled: Bool) -> CacheFormat {
        if !losslessEnabled, format == .matchStream || format == .flacOriginal { return .aac256 }
        return format
    }

    var effectiveDownloadFormat: CacheFormat {
        Self.effectiveFormat(downloadFormat, losslessEnabled: losslessAudioEnabled)
    }

    var allowsWiFiLosslessUpgrade: Bool {
        let format = formatForCurrentNetwork(isLimited: false)
        return format == .matchStream || format == .flacOriginal
    }

    /// Opt-in alternative file selection; takes effect for the next resolved song.
    var preferDolbyAtmos: Bool {
        get { access(keyPath: \.preferDolbyAtmos); return _preferDolbyAtmos }
        set {
            withMutation(keyPath: \.preferDolbyAtmos) { _preferDolbyAtmos = newValue }
            defaults.set(newValue, forKey: Self.atmosKey)
        }
    }
    /// Local Dolby files remain playable; this controls remote Dolby audio only.
    var allowDolbyAtmosOverCellular: Bool {
        get { access(keyPath: \.allowDolbyAtmosOverCellular); return _allowDolbyAtmosOverCellular }
        set {
            guard _allowDolbyAtmosOverCellular != newValue else { return }
            withMutation(keyPath: \.allowDolbyAtmosOverCellular) { _allowDolbyAtmosOverCellular = newValue }
            defaults.set(newValue, forKey: Self.atmosCellularKey)
        }
    }
    private static let atmosCellularKey = "cassette.streaming.allowDolbyAtmosOverCellular"

    func allowsRemoteDolbyAtmos(isCellular: Bool) -> Bool {
        !isCellular || allowDolbyAtmosOverCellular
    }

    private static let atmosKey = "cassette.streaming.preferDolbyAtmos"

    /// When enabled, automatic downloads and the "Download" action in the Now Playing
    /// menu prefer the Dolby Atmos variant of the current track when one is available.
    var preferDolbyAtmosDownload: Bool {
        get { access(keyPath: \.preferDolbyAtmosDownload); return _preferDolbyAtmosDownload }
        set {
            guard _preferDolbyAtmosDownload != newValue else { return }
            withMutation(keyPath: \.preferDolbyAtmosDownload) { _preferDolbyAtmosDownload = newValue }
            defaults.set(newValue, forKey: Self.atmosDownloadKey)
        }
    }
    private static let atmosDownloadKey = "cassette.streaming.preferDolbyAtmosDownload"

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
        _losslessAudioEnabled = defaults.object(forKey: Self.losslessAudioKey) as? Bool ?? true
        _allowDolbyAtmosOverCellular = defaults.object(forKey: Self.atmosCellularKey) as? Bool ?? true
        _preferDolbyAtmos = defaults.bool(forKey: Self.atmosKey)
        _preferDolbyAtmosDownload = defaults.bool(forKey: Self.atmosDownloadKey)
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
    /// bitstream. Lossless choices remain saved while the master switch temporarily caps
    /// automatic/original delivery at AAC 256. Availability depends on the server's files.
    func formatForCurrentNetwork(isLimited: Bool) -> CacheFormat {
        Self.effectiveFormat(isLimited ? cellularFormat : wifiFormat, losslessEnabled: losslessAudioEnabled)
    }

    func reloadFromDefaults() {
        losslessAudioEnabled = defaults.object(forKey: Self.losslessAudioKey) as? Bool ?? true
        allowDolbyAtmosOverCellular = defaults.object(forKey: Self.atmosCellularKey) as? Bool ?? true
        preferDolbyAtmos = defaults.bool(forKey: Self.atmosKey)
        preferDolbyAtmosDownload = defaults.bool(forKey: Self.atmosDownloadKey)
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
