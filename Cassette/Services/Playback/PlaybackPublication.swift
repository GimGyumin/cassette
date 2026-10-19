import Foundation

/// Captured before asynchronous metadata work. An occurrence is the command + item epoch;
/// sequence orders publications within that occurrence without increasing update frequency.
nonisolated struct PlaybackPublication: Sendable {
    let context: PlaybackContext
    let sequence: UInt64
    let authority: PlaybackAuthority
    var isCurrent: Bool { authority.snapshot == context }
    func commit(_ update: () -> Void) { _ = authority.commit(ifCurrent: context, update) }
}

extension PlayerService {
    func makePlaybackPublication() -> PlaybackPublication {
        presentationSequence &+= 1
        return PlaybackPublication(context: playbackContext, sequence: presentationSequence, authority: authority)
    }
}
