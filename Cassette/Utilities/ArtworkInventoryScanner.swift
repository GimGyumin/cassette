import Foundation

/// Incremental disk inventory for background artwork preparation. Missing files never reach
/// ImageIO, and unchanged files (including incomplete downloads) are validated only once.
nonisolated struct ArtworkInventoryScanner: Sendable {
    private struct Fingerprint: Equatable, Sendable {
        let size: Int?
        let modified: Date?
        let created: Date?
    }

    private let expectedNames: Set<String>
    private var fingerprints: [String: Fingerprint] = [:]
    private var validNames: Set<String> = []

    init(expectedNames: Set<String>) { self.expectedNames = expectedNames }

    mutating func scan(directory: URL, validate: (URL) -> Bool) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey,
                                       .contentModificationDateKey, .creationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var present: Set<String> = []
        for file in files {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard expectedNames.contains(name) else { continue }
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            present.insert(name)
            let fingerprint = Fingerprint(size: values.fileSize, modified: values.contentModificationDate,
                                          created: values.creationDate)
            guard fingerprints[name] != fingerprint else { continue }
            fingerprints[name] = fingerprint
            if validate(file) { validNames.insert(name) }
            else { validNames.remove(name) }
        }
        fingerprints = fingerprints.filter { present.contains($0.key) }
        validNames.formIntersection(present)
        return validNames
    }
}
