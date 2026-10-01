import Testing
@testable import Cassette

@Suite("Playback buffering and sustained stalls")
struct PlaybackBufferPolicyTests {
    @Test func localPlaybackNeedsNoNetworkBuffer() {
        #expect(PlaybackBufferPolicy.forwardBuffer(isLocal: true, isLimited: true) == 0)
        #expect(PlaybackBufferPolicy.forwardBuffer(isLocal: false, isLimited: true)
            > PlaybackBufferPolicy.forwardBuffer(isLocal: false, isLimited: false))
    }

    @Test func initialWaitRecoversWithoutAnotherStateChange() {
        var monitor = PlaybackStallMonitor()
        for second in 0..<12 {
            let result1 = !monitor.observe(mediaTime: .nan, now: Double(second), cannotPlay: true, isSeeking: false)
            #expect(result1)
        }
        let result2 = monitor.observe(mediaTime: .nan, now: 12, cannotPlay: true, isSeeking: false)
        #expect(result2)
    }

    @Test func intermittentHiccupsDoNotAccumulateIntoRecovery() {
        var monitor = PlaybackStallMonitor()
        for second in 0..<60 {
            let time = Double(second / 3)
            let result3 = !monitor.observe(mediaTime: time, now: Double(second), cannotPlay: true, isSeeking: false)
            #expect(result3)
        }
    }

    @Test func seekAndHealthyBufferResetTheDeadline() {
        var monitor = PlaybackStallMonitor()
        let result4 = !monitor.observe(mediaTime: 10, now: 0, cannotPlay: true, isSeeking: false)
        #expect(result4)
        let result5 = !monitor.observe(mediaTime: 10, now: 11, cannotPlay: true, isSeeking: true)
        #expect(result5)
        let result6 = !monitor.observe(mediaTime: 100, now: 12, cannotPlay: true, isSeeking: false)
        #expect(result6)
        let result7 = !monitor.observe(mediaTime: 100, now: 13, cannotPlay: true, isSeeking: false)
        #expect(result7)
        let result8 = !monitor.observe(mediaTime: 100, now: 24, cannotPlay: false, isSeeking: false)
        #expect(result8)
        let result9 = !monitor.observe(mediaTime: 100, now: 25, cannotPlay: true, isSeeking: false)
        #expect(result9)
        let result10 = monitor.observe(mediaTime: 100, now: 37, cannotPlay: true, isSeeking: false)
        #expect(result10)
    }
}
