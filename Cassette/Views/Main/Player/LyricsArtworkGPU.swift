import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore

/// Constructed on a worker, then owned by one renderer. Frames share one ordered command queue.
/// SwiftUI never drives this object's frame loop, and rendering never waits for GPU completion.
nonisolated final class LyricsArtworkGPU: @unchecked Sendable {
    struct Frame {
        let texture: any MTLTexture
        let commandBuffer: any MTLCommandBuffer
    }
    enum SetupError: Error { case unavailable }

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let scenePipeline: any MTLRenderPipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private let presentPipeline: any MTLRenderPipelineState
    private let blur: MPSImageGaussianBlur
    private var artwork: (any MTLTexture)?
    private var colorProfile = ArtworkSceneColorProfile.neutral
    private var scene: (any MTLTexture)?
    private var blurred: (any MTLTexture)?
    private var composed: (any MTLTexture)?
    private var previous: (any MTLTexture)?
    private var hasRenderedFrame = false

    init(device: any MTLDevice, bundle: Bundle = .main) throws {
        self.device = device
        guard MPSSupportsMTLDevice(device), let queue = device.makeCommandQueue() else {
            throw SetupError.unavailable
        }
        self.queue = queue
        let library = try device.makeDefaultLibrary(bundle: bundle)
        guard let vertex = library.makeFunction(name: "cassetteLyricsVertex") else {
            throw SetupError.unavailable
        }
        func pipeline(_ name: String, format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            guard let fragment = library.makeFunction(name: name) else { throw SetupError.unavailable }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        scenePipeline = try pipeline("cassetteLyricsScene", format: .rgba16Float)
        compositePipeline = try pipeline("cassetteLyricsComposite", format: .rgba16Float)
        presentPipeline = try pipeline("cassetteLyricsPresent", format: .bgra8Unorm_srgb)
        blur = MPSImageGaussianBlur(device: device, sigma: 24)
        blur.edgeMode = .clamp
        prepareBlur()
    }

    /// MPS can prepare its kernels on the first encode. Do that with pipeline setup on the
    /// worker, rather than on the main thread when the first visible frame is drawn.
    private func prepareBlur() {
        guard let source = makeTexture(width: 64, height: 64),
              let destination = makeTexture(width: 64, height: 64),
              let command = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = source
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: destination)
        command.commit()
    }

    /// Snapshot the displayed composite, including any unfinished fade, before replacing the art.
    /// A rapid A → B → C change therefore fades from the visible result rather than jumping to B.
    @discardableResult
    func replaceArtwork(_ texture: any MTLTexture, profile: ArtworkSceneColorProfile = .neutral, crossfade: Bool) -> Bool {
        guard artwork !== texture else { return false }
        let canFade = crossfade && hasRenderedFrame && composed != nil
        if canFade, let composed,
           let snapshot = makeTexture(width: composed.width, height: composed.height),
           let command = queue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder() {
            encoder.copy(from: composed, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: composed.width, height: composed.height, depth: 1),
                         to: snapshot, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            encoder.endEncoding()
            command.commit()
            previous = snapshot
        } else {
            previous = nil
        }
        artwork = texture
        colorProfile = profile
        return previous != nil
    }

    func render(size: CGSize, elapsed: Float, transition: Float = 1,
                flowSpeed: Double = AMLLArtworkMotion.defaultFlowSpeed,
                drawable: (any CAMetalDrawable)? = nil) -> Frame? {
        guard let artwork else { return nil }
        let dimensions = ArtworkSceneMotion.renderSize(for: size)
        if scene?.width != dimensions.width || scene?.height != dimensions.height {
            hasRenderedFrame = false
            scene = makeTexture(width: dimensions.width, height: dimensions.height)
            blurred = makeTexture(width: dimensions.width, height: dimensions.height)
            composed = makeTexture(width: dimensions.width, height: dimensions.height)
        }
        guard let scene, let blurred, let composed, let command = queue.makeCommandBuffer() else { return nil }
        let speed = AMLLArtworkMotion.speed(flowSpeed)
        let layers = AMLLArtworkMotion.layers(size: CGSize(width: dimensions.width, height: dimensions.height),
                                             elapsed: Double(elapsed), flowSpeed: speed)
        var parameters = SIMD4<Float>(Float(dimensions.width) / Float(dimensions.height), elapsed * Float(speed),
                                      previous == nil ? 1 : transition, 0)
        guard encode(command: command, target: scene, pipeline: scenePipeline, textures: [artwork],
                     parameters: &parameters, layers: layers) else { return nil }
        blur.encode(commandBuffer: command, sourceTexture: scene, destinationTexture: blurred)
        guard encode(command: command, target: composed, pipeline: compositePipeline,
                     textures: [blurred, previous ?? blurred], parameters: &parameters) else { return nil }
        if let drawable {
            guard encode(command: command, target: drawable.texture, pipeline: presentPipeline,
                         textures: [composed], parameters: &parameters) else { return nil }
            command.present(drawable)
        }
        hasRenderedFrame = true
        if transition >= 1 { previous = nil }
        return Frame(texture: composed, commandBuffer: command)
    }

    private func makeTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encode(command: any MTLCommandBuffer, target: any MTLTexture,
                        pipeline: any MTLRenderPipelineState, textures: [any MTLTexture],
                        parameters: inout SIMD4<Float>, layers: [SIMD4<Float>] = []) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&colorProfile, length: MemoryLayout<ArtworkSceneColorProfile>.stride, index: 1)
        if !layers.isEmpty {
            layers.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
