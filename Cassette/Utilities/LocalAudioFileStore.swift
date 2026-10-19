import Foundation

/// Common validation and atomic publication for temporary cache and pinned downloads.
nonisolated enum LocalAudioFileStore {
    static func validate(_ url: URL, size: Int64, mimeType: String?, songID: String) throws {
        let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: Int(size), textEncodingName: nil)
        try AudioResponseValidator.validate(fileAt: url, response: response, songId: songID, logger: .cache)
    }

    /// Immutable completed transfers can share storage. A pin retains its own link, so
    /// cache eviction cannot remove a permanent download. Mutable imports are copied.
    static func install(_ source: URL, at destination: URL, sharesImmutableSource: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".audio-install-\(UUID())")
        defer { StagedFileWrite.discard(staging) }
        if sharesImmutableSource {
            do { try fm.linkItem(at: source, to: staging) }
            catch { try fm.copyItem(at: source, to: staging) }
        } else { try fm.copyItem(at: source, to: staging) }
        try Task.checkCancellation()
        try StagedFileWrite.commit(staging, to: destination)
    }
}
