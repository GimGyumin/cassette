import AVFoundation
import MediaToolbox
import Synchronization

/// Read-only native PCM tap: samples pass through unchanged, including channel layout.
/// The tap owns a separate callback context; no tap/context retain cycle is created.
nonisolated final class NativePlaybackMeterTap: @unchecked Sendable {
    private final class Context {
        let active = Atomic<Bool>(false)
        var format = AudioStreamBasicDescription()
    }
    private let context = Context()
    private var tap: MTAudioProcessingTap?

    init?() {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(context).toOpaque(),
            init: { _, info, storage in
                guard let info else { return }
                storage.pointee = Unmanaged<Context>.fromOpaque(info).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.format = format.pointee
            },
            unprepare: { _ in },
            process: { tap, frames, _, list, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut)
                guard status == noErr, framesOut.pointee > 0 else { return }
                let context = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard context.active.load(ordering: .relaxed) else { return }
                PlaybackBeatMeter.enqueue(bufferList: UnsafePointer(list), format: context.format,
                                          frameCount: framesOut.pointee)
            }
        )
        var created: MTAudioProcessingTap?
        let status: OSStatus
        if #available(iOS 27, macOS 27, *) {
            // A nil preferred format retains the device-optimized PCM layout. On iOS 27
            // track-mix taps also support unprotected HLS; no separate decoder is needed.
            status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, nil, &created)
        } else {
            status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &created)
        }
        guard status == noErr, let created else { return nil }
        tap = created
    }

    @MainActor func attach(to item: AVPlayerItem, trackID: CMPersistentTrackID) {
        let input = AVMutableAudioMixInputParameters()
        input.trackID = trackID
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = (item.audioMix?.inputParameters ?? []) + [input]
        item.audioMix = mix
    }

    func setActive(_ active: Bool) { context.active.store(active, ordering: .relaxed) }
    deinit { context.active.store(false, ordering: .relaxed) }
}
