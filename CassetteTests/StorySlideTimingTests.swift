import Testing
@testable import Cassette

struct StorySlideTimingTests {
    @Test("Holding or backgrounding preserves elapsed time, regardless of pause length")
    func pauseAndResume() {
        var timing = StorySlideTiming(duration: 5)
        timing.resume(at: 100)
        timing.pause(at: 102)
        #expect(timing.progress == 0.4)
        #expect(timing.remaining == 3)
        timing.pause(at: 200)
        #expect(timing.remaining == 3)
        timing.resume(at: 200)
        timing.resume(at: 201)
        timing.pause(at: 202)
        #expect(timing.progress == 0.8)
        #expect(timing.remaining == 1)
    }

    @Test("Late deadlines clamp to completion; restarting begins with a full slide")
    func completeAndRestart() {
        var timing = StorySlideTiming(duration: 5)
        timing.resume(at: 100)
        timing.pause(at: 110)
        #expect(timing.progress == 1)
        #expect(timing.remaining == 0)
        timing.resume(at: 120)
        #expect(timing.startedAt == nil)
        timing = StorySlideTiming(duration: 5)
        #expect(timing.progress == 0)
        #expect(timing.remaining == 5)
    }
}
