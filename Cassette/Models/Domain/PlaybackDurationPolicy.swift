import Foundation

/// AudioStreaming can infer duration from Content-Length / estimated bitrate. During
/// transcoding those two values may describe different encodings (e.g. 4 minutes → 101).
/// Keep a catalog duration unless the estimate agrees; native AVPlayer supplies a timeline.
nonisolated enum PlaybackDurationPolicy {
    static func resolve(catalog: TimeInterval, engine: TimeInterval, engineIsEstimate: Bool,
                        preserveCatalog: Bool = false) -> TimeInterval {
        let catalog = catalog.isFinite && catalog > 0 ? catalog : 0
        let engine = engine.isFinite && engine > 0 ? engine : 0
        if preserveCatalog, catalog > 0 { return catalog }
        guard engine > 0 else { return catalog }
        guard catalog > 0 else { return engine }
        guard engineIsEstimate else { return engine }
        return abs(engine - catalog) <= max(2, catalog * 0.05) ? engine : catalog
    }
}
