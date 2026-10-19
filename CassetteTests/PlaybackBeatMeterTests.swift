import Testing
import Foundation
import AVFoundation
@testable import Cassette

/// Coverage for the audio-thread band analysis that the beat visuals depend on. The function is
/// pure (buffer in, energies out), so it can be asserted exactly instead of eyeballed on a device.
@Suite("PlaybackBeatMeter")
struct PlaybackBeatMeterTests {
    private func buffer(filledWith fill: (Int) -> Float, frameCount: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<Int(frameCount) {
            samples[0][index] = fill(index)
        }
        return buffer
    }

    @Test("Bands split the buffer into equal time slices and report per-slice RMS")
    func bandsSplitBufferIntoTimeSlices() throws {
        // First half silent, second half full scale: the first bands must read silence, the last
        // bands full energy — this is what makes the equalizer react to *when* the beat hits.
        let buffer = try buffer(filledWith: { $0 < 512 ? 0 : 1 })
        let bands = PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 4)
        #expect(bands.count == 4)
        #expect(abs(bands[0]) < 0.0001)
        #expect(abs(bands[1]) < 0.0001)
        #expect(abs(bands[2] - 1) < 0.0001)
        #expect(abs(bands[3] - 1) < 0.0001)
    }

    @Test("Band energies are RMS, not peak")
    func bandsReportRMS() throws {
        // A 0.5-amplitude square wave has RMS 0.5 (a peak-based implementation would report 1.0).
        let buffer = try buffer(filledWith: { _ in 0.5 })
        let bands = PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 2)
        for energy in bands {
            #expect(abs(energy - 0.5) < 0.0001)
        }
    }

    @Test("Degenerate buffers yield a full-length zero array")
    func degenerateInputsAreSafe() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        empty.frameLength = 0
        #expect(PlaybackBeatMeter.bandEnergies(from: empty, bandCount: 4) == [0, 0, 0, 0])
        let buffer = try buffer(filledWith: { _ in 1 })
        #expect(PlaybackBeatMeter.bandEnergies(from: buffer, bandCount: 0).isEmpty)
    }

    @Test("Interleaved stereo reads both channels without advancing past storage")
    func interleavedStereo() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44100, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let data = try #require(buffer.floatChannelData)[0]
        for frame in 0..<1024 { data[frame * 2] = 0; data[frame * 2 + 1] = 1 }
        #expect(PlaybackBeatMeter.bandEnergies(from: buffer).allSatisfy { abs($0 - sqrt(0.5)) < 0.0001 })
    }

    @Test("Native Float64 PCM is analyzed without format conversion")
    func nativeFloat64() throws {
        var samples = Array(repeating: Double(0.25), count: 128)
        let format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 1, mBitsPerChannel: 64, mReserved: 0)
        let result = samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return PlaybackBeatMeter.bandEnergies(bufferList: &list, format: format, frameCount: 128)
        }
        #expect(result == [0.25, 0.25, 0.25, 0.25])
    }
}
