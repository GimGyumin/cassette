import SwiftUI
import MetalKit
import QuartzCore

/// Artwork textures create the color field. This view never observes the audio meter or lyrics clock.
struct AppleMusicLyricsBackground: View {
    let coverImage: PlatformImage?
    let fallbackColor: Color
    let isPlaying: Bool
    var animated = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var governor = PerformanceGovernor.shared
    @State private var isVisible = false
    @State private var metalUnavailable = false

    var body: some View {
        ZStack {
            fallbackColor
            if metalUnavailable {
                if let coverImage {
                    Image(platformImage: coverImage)
                        .resizable().scaledToFill().scaleEffect(1.3)
                        .saturation(0.95).blur(radius: 64, opaque: true)
                        .overlay(Color.black.opacity(0.24))
                }
            } else {
                LyricsMetalSurface(
                    image: coverImage,
                    framesPerSecond: governor.budget.artworkFramesPerSecond,
                    renderEnabled: isVisible && scenePhase == .active,
                    motionEnabled: isPlaying && animated && !reduceMotion && governor.budget.allowsArtworkMotion,
                    transitionEnabled: animated && !reduceMotion && governor.budget.allowsDecorativeMotion && !governor.budget.isMemoryPressured,
                    onUnavailable: { metalUnavailable = true }
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: governor.budget.isMemoryPressured) { _, pressured in
            if pressured { Task { await ArtworkSceneTextureCache.shared.removeCachedArtwork() } }
        }
    }
}

private struct LyricsMetalSurface {
    let image: PlatformImage?
    let framesPerSecond: Int
    let renderEnabled: Bool
    let motionEnabled: Bool
    let transitionEnabled: Bool
    let onUnavailable: () -> Void

    func makeCoordinator() -> LyricsSceneCoordinator { LyricsSceneCoordinator(onUnavailable: onUnavailable) }
    private func makeSurface(coordinator: LyricsSceneCoordinator) -> ArtworkMetalView {
        let view = ArtworkMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = framesPerSecond
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.layer?.isOpaque = false
        #endif
        #if os(iOS)
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        #else
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        #endif
        coordinator.attach(view)
        return view
    }
}

#if os(iOS)
extension LyricsMetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateUIView(_ view: ArtworkMetalView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.update(image: image, renderEnabled: renderEnabled, motionEnabled: motionEnabled, transitionEnabled: transitionEnabled)
    }
    static func dismantleUIView(_ view: ArtworkMetalView, coordinator: LyricsSceneCoordinator) { coordinator.stop() }
}
#else
extension LyricsMetalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> ArtworkMetalView { makeSurface(coordinator: context.coordinator) }
    func updateNSView(_ view: ArtworkMetalView, context: Context) {
        view.preferredFramesPerSecond = framesPerSecond
        context.coordinator.update(image: image, renderEnabled: renderEnabled, motionEnabled: motionEnabled, transitionEnabled: transitionEnabled)
    }
    static func dismantleNSView(_ view: ArtworkMetalView, coordinator: LyricsSceneCoordinator) { coordinator.stop() }
}
#endif

/// The drawable itself is low resolution; only the background is upscaled by the compositor.
private final class ArtworkMetalView: MTKView {
    var onResize: (() -> Void)?
    #if os(iOS)
    override func layoutSubviews() { super.layoutSubviews(); onResize?() }
    #else
    override func layout() { super.layout(); onResize?() }
    #endif
}

@MainActor
private final class LyricsSceneCoordinator: NSObject, MTKViewDelegate {
    private weak var view: ArtworkMetalView?
    private var gpu: LyricsArtworkGPU?
    private var setupTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var requestedImage: PlatformImage?
    private var submittedImageID: ObjectIdentifier?
    private var renderEnabled = false
    private var motionEnabled = false
    private var clock = ArtworkSceneClock()
    private var fadeClock = ArtworkSceneClock()
    private var transitionEnabled = false
    private var transitionStartedAt: TimeInterval?
    private let inFlight = DispatchSemaphore(value: 2)
    private let onUnavailable: () -> Void

    init(onUnavailable: @escaping () -> Void) { self.onUnavailable = onUnavailable }

    func attach(_ view: ArtworkMetalView) {
        self.view = view
        view.delegate = self
        view.onResize = { [weak self] in self?.resize() }
        guard let device = view.device else {
            Task { @MainActor [weak self] in self?.onUnavailable() }
            return
        }
        setupTask = Task { [weak self] in
            let gpu = await ArtworkRendererPreparation.shared.renderer(device: device)
            guard !Task.isCancelled, let self else { return }
            setupTask = nil
            guard let gpu else { onUnavailable(); return }
            self.gpu = gpu
            resize()
            submitArtworkIfNeeded()
        }
    }

    func update(image: PlatformImage?, renderEnabled: Bool, motionEnabled: Bool, transitionEnabled: Bool) {
        let wasEnabled = self.renderEnabled
        let wasMoving = self.motionEnabled
        self.renderEnabled = renderEnabled
        self.motionEnabled = renderEnabled && motionEnabled
        self.transitionEnabled = transitionEnabled
        requestedImage = image
        let now = CACurrentMediaTime()
        clock.setRunning(self.motionEnabled, now: now)
        fadeClock.setRunning(renderEnabled && transitionEnabled, now: now)
        if !transitionEnabled { transitionStartedAt = nil }
        updateTicker()
        if !renderEnabled {
            if artworkTask != nil { submittedImageID = nil }
            artworkTask?.cancel()
            artworkTask = nil
            return
        }
        submitArtworkIfNeeded()
        if !self.motionEnabled, wasMoving || !wasEnabled { view?.draw() }
    }

    private func updateTicker() {
        view?.isPaused = !(renderEnabled && (motionEnabled || (transitionEnabled && transitionStartedAt != nil)))
    }

    private func submitArtworkIfNeeded() {
        guard renderEnabled, let gpu, let image = requestedImage else { return }
        let id = ObjectIdentifier(image)
        guard id != submittedImageID else { return }
        submittedImageID = id
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            let prepared = await ArtworkSceneTextureCache.shared.artwork(image: image, device: gpu.device)
            guard !Task.isCancelled, let self, renderEnabled, submittedImageID == id else { return }
            artworkTask = nil
            guard let prepared else { submittedImageID = nil; onUnavailable(); return }
            let crossfade = gpu.replaceArtwork(prepared.texture, profile: prepared.profile, crossfade: transitionEnabled)
            transitionStartedAt = crossfade ? fadeClock.sample(now: CACurrentMediaTime()) : nil
            updateTicker()
            view?.draw()
        }
    }

    private func resize() {
        guard let view else { return }
        let size = ArtworkSceneMotion.renderSize(for: view.bounds.size)
        let drawableSize = CGSize(width: size.width, height: size.height)
        if view.drawableSize != drawableSize { view.drawableSize = drawableSize }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            if renderEnabled, !motionEnabled { view.draw() }
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    private func drawFrame(in view: MTKView) {
        guard renderEnabled, let gpu, view.bounds.width > 0, view.bounds.height > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable else { inFlight.signal(); return }
        let now = CACurrentMediaTime()
        let time = clock.sample(now: now)
        let progress = transitionStartedAt.map { ArtworkSceneMotion.crossfadeProgress(elapsed: fadeClock.sample(now: now) - $0) } ?? 1
        guard let frame = gpu.render(size: view.bounds.size, elapsed: Float(time), transition: progress, drawable: drawable) else {
            inFlight.signal()
            return
        }
        if progress >= 1 { transitionStartedAt = nil; updateTicker() }
        let gate = inFlight
        frame.commandBuffer.addCompletedHandler { _ in gate.signal() }
        frame.commandBuffer.commit()
    }

    func stop() {
        view?.isPaused = true
        view?.delegate = nil
        view?.onResize = nil
        setupTask?.cancel()
        artworkTask?.cancel()
        setupTask = nil
        artworkTask = nil
        gpu = nil
        requestedImage = nil
    }

}
