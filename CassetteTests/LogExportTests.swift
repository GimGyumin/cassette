import Foundation
import Testing
@testable import Cassette

@Suite("Developer log export")
struct LogExportTests {
    @Test func boundedExportRetainsNewestCompleteUtf8Lines() {
        var buffer = LogExportService.RecentLogBuffer(limit: 16)
        buffer.append("old entry\n")
        buffer.append("최근 로그\n")
        #expect(buffer.truncated)
        #expect(buffer.text == "최근 로그\n")
        buffer.append(String(repeating: "x", count: 20))
        #expect(buffer.text == "최근 로그\n")
        #expect(buffer.text.utf8.count <= 16)
    }
    @Test func archiveSurvivesRefreshAndKeepsOnlyTwentySessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("log-archive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<22 {
            let file = directory.appendingPathComponent("Cassette-fixture-\(index).txt")
            try "password=private-value\nformat=flac".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 100))], ofItemAtPath: file.path)
        }
        let unrelated = directory.appendingPathComponent("keep.txt")
        try "untouched".write(to: unrelated, atomically: true, encoding: .utf8)
        try await LogExportService.captureCurrentSession(directory: directory)
        let first = try LogExportService.list(directory: directory)
        #expect(first.count == 20)
        #expect(!first.contains { $0.name == "Cassette-fixture-0.txt" })
        let snapshot = try #require(first.first)
        #expect(try await LogExportService.read(snapshot).contains("Current process"))
        let archived = try #require(first.last)
        #expect(!(try await LogExportService.read(archived)).contains("private-value"))
        try await LogExportService.captureCurrentSession(directory: directory)
        let second = try LogExportService.list(directory: directory)
        #expect(second.map(\.url) == first.map(\.url))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func credentialsAreRedactedWhileFormatDiagnosticsRemain() {
        let message = "GET https://username:password@example.invalid/stream?id=track&format=raw&t=topsecret&s=salt Authorization: Bearer mytoken"
        let sanitized = LogExportService.redact(message)
        for secret in ["username", "password", "topsecret", "salt", "mytoken"] {
            #expect(!sanitized.contains(secret))
        }
        #expect(sanitized.contains("format=raw"))
        #expect(!LogExportService.redact("{\"client_secret\":\"hidden\",\"access_token\":\"another\"}").contains("hidden"))
        #expect(!LogExportService.redact("X-Emby-Token=token123").contains("token123"))
        #expect(!LogExportService.redact("Authorization: Basic c2VjcmV0").contains("c2VjcmV0"))
    }

    @Test func exportsAReadableTextFile() async throws {
        let file = try await LogExportService.export()
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(file.pathExtension == "txt")
        #expect(text.contains("Cassette"))
        #expect(text.contains("Current process"))
        #expect(!text.isEmpty)
    }
}
