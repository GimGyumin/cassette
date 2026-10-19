import Foundation
import Metal
import Observation

/// Bounded startup work: shared page/player palette, restored artwork and one GPU renderer.
/// No audio engine is started and no library-wide textures are retained.
@Observable @MainActor
final class NowPlayingBackgroundPreparation {
    private(set) var isReady = false
    private var task: Task<Void, Never>?
    private var serverID: UUID?
    private var generation = 0

    func prepare(using container: AppContainer, refreshArtwork: Bool = false) async {
        let id = container.serverState.activeServer?.id
        if serverID != id { task?.cancel(); task = nil; isReady = false; serverID = id }
        if isReady && !refreshArtwork { return }
        if let task { await task.value; return }
        isReady = false
        generation &+= 1
        let requestGeneration = generation
        let job = Task { [weak self, weak container] in
            guard let container else { return }
            await ArtworkRendererPreparation.shared.warm()
            let saved = if let id { await container.sessionService.currentTrackForArtworkPreparation(accountID: id) } else { nil as DisplayableSong? }
            guard !Task.isCancelled, container.serverState.activeServer?.id == id else { return }
            let track = container.playerState.currentTrack ?? saved
            if let coverID = container.playbackCoverId(for: track) ?? track?.effectiveCoverArtId {
                _ = await AlbumCoverPreloadService.prepareTheme(for: coverID,
                    artworkImageCache: container.artworkImageCache,
                    dominantColorExtractor: container.dominantColorExtractor)
                if let image = await container.artworkImageCache.load(coverArtId: coverID, tier: .hero, allowNetwork: false),
                   let device = MTLCreateSystemDefaultDevice(), !Task.isCancelled {
                    _ = await ArtworkSceneTextureCache.shared.artwork(image: image, device: device)
                }
            }
            guard !Task.isCancelled, container.serverState.activeServer?.id == id else { return }
            self?.isReady = true
        }
        task = job
        await job.value
        if generation == requestGeneration { task = nil }
    }
}
