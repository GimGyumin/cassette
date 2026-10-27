import Foundation
import Testing
@testable import Cassette

struct ArtworkInventoryScannerTests {
    @Test func validatesOnlyNewOrChangedExpectedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var scanner = ArtworkInventoryScanner(expectedNames: ["cover", "missing"])
        var checks = 0
        func scan() throws -> Set<String> {
            try scanner.scan(directory: directory) { url in
                checks += 1
                return (try? String(contentsOf: url, encoding: .utf8)) == "complete"
            }
        }
        let cover = directory.appendingPathComponent("cover")
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("thumbnail"))
        #expect(try scan().isEmpty)
        #expect(checks == 0)
        try Data("partial".utf8).write(to: cover)
        #expect(try scan().isEmpty)
        for _ in 0..<10 { #expect(try scan().isEmpty) }
        #expect(checks == 1)
        try Data("complete".utf8).write(to: cover, options: .atomic)
        #expect(try scan() == ["cover"])
        for _ in 0..<10 { #expect(try scan() == ["cover"]) }
        #expect(checks == 2)
        try FileManager.default.removeItem(at: cover)
        #expect(try scan().isEmpty)
        try Data("complete".utf8).write(to: cover)
        #expect(try scan() == ["cover"])
        #expect(checks == 3)
    }

    @Test func sameSizeReplacementIsRevalidated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover")
        var scanner = ArtworkInventoryScanner(expectedNames: ["cover"])
        try Data("bad".utf8).write(to: cover)
        #expect(try scanner.scan(directory: directory) { _ in false }.isEmpty)
        try Data("new".utf8).write(to: cover)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: cover.path)
        #expect(try scanner.scan(directory: directory) { _ in true } == ["cover"])
    }

    @Test func cancelledScanDoesNotValidateFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("cover"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var scanner = ArtworkInventoryScanner(expectedNames: ["cover"])
            do {
                _ = try scanner.scan(directory: directory) { _ in
                    Issue.record("Cancelled inventory decoded artwork")
                    return true
                }
                Issue.record("Cancelled inventory completed")
            } catch { #expect(error is CancellationError) }
        }
        await task.value
    }
}
