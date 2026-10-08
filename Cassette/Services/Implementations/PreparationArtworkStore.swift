import Foundation

/// Small immutable widget images; originals remain untouched in the download store.
@MainActor
final class PreparationArtworkStore {
    struct Asset: Sendable {
        let id: String
        let backgroundRGB: Int?
    }
    private let cache: ArtworkImageCache
    private var previousCover: String?
    private var previousAsset: Asset?
    private var recentFiles: [URL] = []
    private var restoredFiles = false

    init(cache: ArtworkImageCache) { self.cache = cache }

    func prepare(coverID: String) async -> Asset? {
        if previousCover == coverID, let previousAsset,
           let directory = SharedStorage.coverArtCacheDirectory,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(previousAsset.id).jpg").path) { return previousAsset }
        guard let directory = SharedStorage.coverArtCacheDirectory,
              let image = await cache.load(coverArtId: coverID, tier: .thumb, allowNetwork: false) else { return nil }
        let background = ColorCache.palette(for: coverID)?.packedBackground
        let result = await Task.detached(priority: .utility) {
            // Progress updates reuse the prepared palette instead of analyzing the image again.
            (image.resized(maxDimension: 128).jpgData(quality: 0.85), background)
        }.value
        guard let bytes = result.0, !Task.isCancelled else { return nil }
        let id = "preparation-\(UUID().uuidString)"
        let file = directory.appendingPathComponent("\(id).jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !restoredFiles {
                restoredFiles = true
                recentFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
                    .filter { $0.lastPathComponent.hasPrefix("preparation-") }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) } ?? []
            }
            try bytes.write(to: file, options: .atomic)
            recentFiles.append(file)
            // Keep several previous frames available while the system transitions its activity UI.
            while recentFiles.count > 8 { try? FileManager.default.removeItem(at: recentFiles.removeFirst()) }
            let asset = Asset(id: id, backgroundRGB: result.1)
            previousCover = coverID
            previousAsset = asset
            return asset
        } catch { return nil }
    }
}
