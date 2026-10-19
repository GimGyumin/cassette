import Foundation

/// Stored in PlaybackSession.id, so existing stores need no schema migration. A revision
/// identifies one occurrence, including repeated copies of a song at the same queue index.
nonisolated struct PlaybackCheckpointIdentity: Sendable, Equatable {
    let accountID: UUID
    let trackID: String
    let queueIndex: Int
    let revision: String
    var storageKey: String { "current:\(accountID.uuidString):\(revision)" }
    static func prefix(for accountID: UUID) -> String { "current:\(accountID.uuidString):" }
}
