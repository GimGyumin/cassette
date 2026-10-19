import Foundation
import Metal
import Testing
@testable import Cassette

@Suite("Artwork renderer preparation")
struct ArtworkRendererPreparationTests {
    @Test("Concurrent startup warmups hand an exclusive renderer to each surface")
    func exclusiveRenderers() async throws {
        let pool = ArtworkRendererPreparation()
        async let firstWarm: Void = pool.warm()
        async let secondWarm: Void = pool.warm()
        _ = await (firstWarm, secondWarm)
        let device = try #require(MTLCreateSystemDefaultDevice())
        async let first = pool.renderer(device: device)
        async let second = pool.renderer(device: device)
        let renderers = await (first, second)
        let a = try #require(renderers.0), b = try #require(renderers.1)
        #expect(a !== b)
    }
}
