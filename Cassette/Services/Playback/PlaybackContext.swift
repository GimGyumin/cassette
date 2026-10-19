import Foundation
import Synchronization

/// A command and the item lifetime it belongs to. Engine/seek generations remain separate:
/// cancelling a seek must not invalidate unrelated artwork or the queue's prepared item.
nonisolated struct PlaybackContext: Sendable, Equatable {
    var command: UInt64 = 0
    var epoch: UInt64 = 0
}

/// Only PlayerService changes this authority. The UI commits under the same short lock so an
/// actor hop cannot publish an old state after a newer command. Never used on an audio thread.
nonisolated final class PlaybackAuthority: Sendable {
    private let value = Mutex(PlaybackContext())
    var snapshot: PlaybackContext { value.withLock { $0 } }
    func setCommand(_ command: UInt64) { value.withLock { $0.command = command } }
    func setEpoch(_ epoch: UInt64) { value.withLock { $0.epoch = epoch } }
    func commit<Value>(ifCurrent context: PlaybackContext, _ body: () -> Value) -> Value? {
        value.withLock { current in
            guard current == context else { return nil }
            return body()
        }
    }
}

nonisolated enum PlaybackIntent: Sendable { case play, pause, stop }

/// Control intent is independent of an engine's transient status and of the UI projection.
nonisolated struct PlaybackTransportModel: Sendable {
    var intent: PlaybackIntent?
    var interrupted = false
    var terminalContext: PlaybackContext?
    var permitsAudio: Bool { !interrupted && intent != .pause && intent != .stop }
}
