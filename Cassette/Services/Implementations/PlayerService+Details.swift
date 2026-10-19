import Foundation
#if os(iOS)
import AVFAudio
#endif

extension PlayerService {
    func playbackDetails() async -> PlaybackDetails? {
        guard let currentSource else { return nil }
        var details = PlaybackDetails(source: currentSource, usesSystemPlayer: systemPlayback.isActive,
                                      actualCodec: systemPlayback.isActive ? systemEngine.actualCodec : nil)
        details.replayGainStatus = playbackGain.status(capabilities: engineCapabilities)
        details.requestedGainDB = playbackGain.requestedDB
        details.appliedGainDB = engineCapabilities.appliedGainDB(requested: playbackGain.requestedDB)
        #if os(iOS)
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        if sampleRate.isFinite, sampleRate > 0 { details.audioSessionSampleRate = sampleRate }
        #endif
        return details
    }
}
