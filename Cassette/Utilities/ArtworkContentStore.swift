import Foundation
import CryptoKit
import Synchronization

/// Content sharing preserves every public artwork path. Removing one hard link cannot
/// invalidate another track's artwork; atomic replacement never mutates shared bytes.
nonisolated enum ArtworkContentStore {
    private struct Index: Sendable {
        var files: [String: Set<URL>] = [:]
        var reconciled: Set<URL> = []
    }
    private static let index = Mutex(Index())

    static func write(_ data: Data, to destination: URL) throws {
        try index.withLock { state in
            try install(data, to: destination, files: &state.files)
        }
    }

    /// Run on a utility worker. Existing originals, derivatives and legacy artwork
    /// participate, but unrelated/invalid files are never treated as image sources.
    static func reconcile(directory: URL) throws {
        try index.withLock { state in
            guard !state.reconciled.contains(directory) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for file in files {
                try Task.checkCancellation()
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      CassetteBackgroundDownloads.isValidArtwork(at: file),
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                try install(data, to: file, files: &state.files)
            }
            state.reconciled.insert(directory)
        }
    }

    private static func install(_ data: Data, to destination: URL, files: inout [String: Set<URL>]) throws {
        let directory = destination.deletingLastPathComponent()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/" + digest
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Verify cached paths: clearing caches or replacing a cover must not link stale bytes.
        let source = files[key]?.first { candidate in
            (try? Data(contentsOf: candidate, options: .mappedIfSafe)) == data
        }
        if let source {
            if source == destination || fileIdentity(source) == fileIdentity(destination) {
                files[key, default: []].insert(destination)
                return
            }
            let staged = directory.appendingPathComponent(".artwork-link-\(UUID())")
            defer { StagedFileWrite.discard(staged) }
            try fm.linkItem(at: source, to: staged)
            try StagedFileWrite.commit(staged, to: destination)
        } else {
            // During migration the file already has the correct bytes; avoid rewriting it.
            if (try? Data(contentsOf: destination, options: .mappedIfSafe)) != data {
                try data.write(to: destination, options: .atomic)
            }
        }
        files[key, default: []].insert(destination)
    }

    static func fileIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
}
