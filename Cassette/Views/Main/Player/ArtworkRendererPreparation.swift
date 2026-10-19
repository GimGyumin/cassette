import Foundation
import Metal

/// One idle renderer is warmed during app preparation and transferred to its first surface.
/// Mutable frame buffers/queues are never shared by two visible renderers.
actor ArtworkRendererPreparation {
    static let shared = ArtworkRendererPreparation()
    private var prepared: LyricsArtworkGPU?
    private var worker: Task<LyricsArtworkGPU?, Never>?
    private var workerID: UUID?

    func warm() async {
        guard prepared == nil else { return }
        if worker == nil {
            workerID = UUID()
            worker = Task.detached(priority: .utility) {
                guard let device = MTLCreateSystemDefaultDevice() else { return nil }
                return try? LyricsArtworkGPU(device: device)
            }
        }
        let id = workerID
        let result = await worker?.value
        guard workerID == id else { return }
        prepared = result
        worker = nil
        workerID = nil
    }

    func renderer(device: any MTLDevice) async -> LyricsArtworkGPU? {
        if worker != nil { await warm() }
        if let prepared, prepared.device.registryID == device.registryID {
            self.prepared = nil
            return prepared
        }
        let task = Task.detached(priority: .utility) { try? LyricsArtworkGPU(device: device) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
