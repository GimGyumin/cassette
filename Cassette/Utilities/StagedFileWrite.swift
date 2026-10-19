import Darwin
import Foundation

/// Bulk I/O is staged on a worker in the destination filesystem. The owner may then
/// validate its account/generation and perform a single atomic rename without copying bytes.
nonisolated enum StagedFileWrite {
    static func stage(_ data: Data, beside destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".cassette-staged-\(UUID().uuidString)")
        do { try data.write(to: staged, options: .withoutOverwriting); return staged }
        catch { discard(staged); throw error }
    }

    static func commit(_ staged: URL, to destination: URL) throws {
        let result = staged.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func discard(_ staged: URL) { try? FileManager.default.removeItem(at: staged) }
}
