import Foundation
import AVFoundation

/// An explicit AAC download cannot be committed as a lossless file when a server ignores format.
/// Conversion uses bounded PCM buffers on a utility worker, never the main/audio-render thread.
nonisolated enum AACDownloadEncoder {
    struct Result: Sendable {
        let url: URL
        let wasEncoded: Bool
    }

    static func prepare(fileAt url: URL, bitRate: Int) async throws -> Result {
        let worker = Task.detached(priority: .utility) {
            try await AACEncodingWorker.shared.encode(fileAt: url, bitRate: bitRate)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    fileprivate static func encodeIfNeeded(fileAt url: URL, bitRate: Int) throws -> Result {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: url)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        guard duration > 0, size > 0 else { throw CassetteError.mediaNotFound(songId: "download") }
        if input.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
           size * 8 / duration <= Double(bitRate) * 1.25 {
            return Result(url: url, wasEncoded: false)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cassette-aac-\(UUID().uuidString).m4a")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: destination) } }
        try convert(input: input, destination: destination, bitRate: bitRate)
        try Task.checkCancellation()
        let verified = try AVAudioFile(forReading: destination)
        guard verified.length > 0, verified.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            throw CassetteError.mediaNotFound(songId: "download")
        }
        success = true
        return Result(url: destination, wasEncoded: true)
    }

    private static func convert(input: AVAudioFile, destination: URL, bitRate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: min(48_000, input.processingFormat.sampleRate),
            AVNumberOfChannelsKey: min(2, input.processingFormat.channelCount),
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8_192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 8_192) else {
            throw CassetteError.mediaNotFound(songId: "download")
        }
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            var readError: (any Error)?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { frames, inputStatus in
                do {
                    let remaining = input.length - input.framePosition
                    guard remaining > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    try input.read(into: inputBuffer, frameCount: min(frames, inputBuffer.frameCapacity,
                        AVAudioFrameCount(min(remaining, AVAudioFramePosition(inputBuffer.frameCapacity)))))
                    inputStatus.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                    return inputBuffer.frameLength > 0 ? inputBuffer : nil
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            if status == .endOfStream { break }
            if status == .error { throw CassetteError.mediaNotFound(songId: "download") }
        }
    }
}

/// Disk transfers can overlap, CPU encoders cannot. A synchronous actor operation avoids
/// three simultaneous converters heating the device during an album download.
private actor AACEncodingWorker {
    static let shared = AACEncodingWorker()
    func encode(fileAt url: URL, bitRate: Int) throws -> AACDownloadEncoder.Result {
        try Task.checkCancellation()
        return try AACDownloadEncoder.encodeIfNeeded(fileAt: url, bitRate: bitRate)
    }
}
