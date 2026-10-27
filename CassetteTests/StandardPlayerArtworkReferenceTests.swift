import CoreGraphics
import ImageIO
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import Cassette

@Suite("Standard player screenshot reference")
@MainActor
struct StandardPlayerArtworkReferenceTests {
    @Test(arguments: [true, false])
    func artworkMatchesSuppliedScreenshot(playing: Bool) throws {
        // The screenshots are 588×1280. Compare in a 402pt phone viewport.
        let pixelScale: CGFloat = 588.0 / 402.0
        let viewport = CGSize(width: 402, height: 1280 / pixelScale)
        let renderer = ImageRenderer(content:
            ImmersivePlayerControlsLayout(topInset: 62, bottomInset: 34, showsStandardArtwork: true) {
                Color.green
                Color.blue
                Color.blue
                Color.blue
                Color.blue
                StandardPlayerArtworkSlot(isPlaying: playing, reduceMotion: false) { _ in
                    Color(.sRGB, red: 1, green: 0, blue: 0)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .background(.black)
        )
        renderer.scale = pixelScale
        let image = try #require(renderer.cgImage)
        let rect = try artworkBounds(image)
        let reference = playing ? CGRect(x: 35, y: 140, width: 518, height: 518)
            : CGRect(x: 105, y: 210, width: 378, height: 378)
        #expect(abs(rect.minX - reference.minX) <= 2)
        #expect(abs(rect.minY - reference.minY) <= 2)
        #expect(abs(rect.width - reference.width) <= 2)
        #expect(abs(rect.height - reference.height) <= 2)
        // Native renderer diagnostic, not a manipulated user screenshot.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cassette-standard-reference-\(playing ? "playing" : "paused").png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        print("Artwork reference render: \(url.path)")
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func transportChangesDeliverAnimationTransactions(reduceMotion: Bool) async throws {
        let recorder = ArtworkAnimationRecorder()
        func scene(_ playing: Bool) -> ArtworkAnimationScene {
            ArtworkAnimationScene(playing: playing, reduceMotion: reduceMotion, recorder: recorder)
        }
        let host = NSHostingView(rootView: scene(false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for playing in [true, false, true] {
            recorder.samples.removeAll()
            host.rootView = scene(playing)
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while !recorder.samples.contains(where: { $0.playing == playing }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
            }
            let sample = try #require(recorder.samples.last(where: { $0.playing == playing }))
            #expect(sample.animated == !reduceMotion)
            #expect(!sample.disabled)
        }
    }
    #endif

    @Test func artworkClearsTitleAndHandleOnSmallAndLargePhones() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 393, height: 852), CGSize(width: 402, height: 874),
                     CGSize(width: 430, height: 932)] {
            let metrics = ImmersivePlayerMetrics(size: size, topInset: size.height > 800 ? 62 : 20,
                                                bottomInset: size.height > 800 ? 34 : 0)
            let art = metrics.standardArtworkFrame
            #expect(art.width == art.height && art.width > 0)
            #expect(art.minY >= metrics.topInset + ImmersivePlayerMetrics.panelTopGap)
            #expect(art.maxY <= metrics.infoTop - CassetteSpacing.xl + 0.01)
            #expect(art.minX >= 24 && art.maxX <= size.width - 24)
        }
    }

    private func artworkBounds(_ image: CGImage) throws -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var result = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i] > 230 && pixels[i + 1] < 20 && pixels[i + 2] < 20 {
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return result
    }
}

#if os(macOS)
@MainActor
private final class ArtworkAnimationRecorder {
    var samples: [(playing: Bool, animated: Bool, disabled: Bool)] = []
}

private struct ArtworkAnimationScene: View {
    let playing: Bool
    let reduceMotion: Bool
    let recorder: ArtworkAnimationRecorder
    var body: some View {
        ArtworkAnimationProbe(playing: playing, recorder: recorder)
            .frame(width: 200, height: 200)
            .modifier(PlayerArtworkPlaybackModifier(isPlaying: playing, reduceMotion: reduceMotion))
            .frame(width: 240, height: 240)
    }
}

private struct ArtworkAnimationProbe: NSViewRepresentable {
    let playing: Bool
    let recorder: ArtworkAnimationRecorder
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        recorder.samples.append((playing, context.transaction.animation != nil, context.transaction.disablesAnimations))
    }
}
#endif
