import Testing
@testable import Cassette

@Suite("Playback buffering and sustained stalls")
struct PlaybackBufferPolicyTests {
    @Test func nextTrackPreparationRequiresContinuousClockAndResetsAfterAStallOrSeek() {
        var stability = PlaybackPreparationStability()
        let observed1 = stability.observe(mediaTime: 1, now: 0, isPlaying: true)
        #expect(!observed1)
        let observed2 = stability.observe(mediaTime: 2, now: 1, isPlaying: true)
        #expect(!observed2)
        let observed3 = stability.observe(mediaTime: 3, now: 2, isPlaying: true)
        #expect(observed3)
        let observed4 = stability.observe(mediaTime: 3, now: 3, isPlaying: true)
        #expect(!observed4)
        let observed5 = stability.observe(mediaTime: 4, now: 4, isPlaying: true)
        #expect(!observed5)
        let observed6 = stability.observe(mediaTime: 5, now: 5, isPlaying: true)
        #expect(observed6)
        let observed7 = stability.observe(mediaTime: 0, now: 6, isPlaying: true)
        #expect(!observed7)
        let observed8 = stability.observe(mediaTime: 1, now: 7, isPlaying: false)
        #expect(!observed8)
        let observed9 = stability.observe(mediaTime: 2, now: 20, isPlaying: true)
        #expect(!observed9)
        let observed10 = stability.observe(mediaTime: .nan, now: 21, isPlaying: true)
        #expect(!observed10)
        #expect(PlaybackBufferPolicy.canPrepareNext(isLocal: false, bufferedAhead: 5, remaining: 150))
        #expect(!PlaybackBufferPolicy.canPrepareNext(isLocal: false, bufferedAhead: 4.9, remaining: 150))
    }

    @Test func currentStreamKeepsBufferBeforeNextTrackStartsDownloading() {
        #expect(!PlaybackBufferPolicy.canPrepareNext(isLocal: false, bufferedAhead: 1, remaining: 150))
        #expect(PlaybackBufferPolicy.canPrepareNext(isLocal: false, bufferedAhead: 10, remaining: 150))
        #expect(PlaybackBufferPolicy.canPrepareNext(isLocal: false, bufferedAhead: 4.5, remaining: 5))
        #expect(PlaybackBufferPolicy.canPrepareNext(isLocal: true, bufferedAhead: 0, remaining: 150))
        #expect(PlaybackBufferPolicy.recoveryBuffer(startup: 1) > 1)
        #expect(PlaybackBufferPolicy.recoveryBuffer(startup: 2) > 2)
    }
    @Test func promptStartupRequiresPlayableBufferAndKeepsTheLimitedNetworkCushion() {
        let normal = PlaybackBufferPolicy.startupBuffer(isLimited: false)
        let limited = PlaybackBufferPolicy.startupBuffer(isLimited: true)
        #expect(limited > normal)
        #expect(!PlaybackBufferPolicy.canStartPromptly(bufferedAhead: normal - 0.1, minimum: normal))
        #expect(PlaybackBufferPolicy.canStartPromptly(bufferedAhead: normal, minimum: normal))
        #expect(!PlaybackBufferPolicy.canStartPromptly(bufferedAhead: normal, minimum: limited))
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            #expect(!PlaybackBufferPolicy.canStartPromptly(bufferedAhead: invalid, minimum: normal))
            #expect(!PlaybackBufferPolicy.canStartPromptly(bufferedAhead: 10, minimum: invalid))
        }
    }
    @Test func bufferBehindSeekTargetDoesNotCountAsPlayableAudio() {
        let ranges: [(start: Double, duration: Double)] = [(0, 120), (240, 10)]
        #expect(PlaybackBufferPolicy.bufferedAhead(position: 245, ranges: ranges) == 5)
        #expect(PlaybackBufferPolicy.bufferedAhead(position: 180, ranges: ranges) == 0)
        #expect(PlaybackBufferPolicy.bufferedAhead(position: 250, ranges: ranges) == 0)
        #expect(PlaybackBufferPolicy.bufferedAhead(position: .nan, ranges: ranges) == 0)
    }
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
