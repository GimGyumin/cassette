import Foundation
import OSLog

nonisolated enum LogExportService {
    struct RecentLogBuffer {
        let limit: Int
        private var lines: [(text: String, bytes: Int)] = []
        private var head = 0
        private var bytes = 0
        private(set) var truncated = false

        mutating func append(_ line: String) {
            let cost = line.utf8.count
            guard cost <= limit else { truncated = true; return }
            while bytes + cost > limit, head < lines.count {
                bytes -= lines[head].bytes
                head += 1
                truncated = true
            }
            lines.append((line, cost))
            bytes += cost
            if head > 1024 { lines.removeFirst(head); head = 0 }
        }
        var text: String { lines.dropFirst(head).map(\.text).joined() }
    }
    struct LogFile: Identifiable, Hashable, Sendable {
        let url: URL
        let modifiedAt: Date
        let bytes: Int
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    private static let sessionName: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Cassette-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).txt"
    }()

    static var archiveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cassette/Logs", isDirectory: true)
    }

    /// Refresh one file per process, retaining a bounded archive across app launches.
    static func captureCurrentSession(directory: URL = archiveDirectory) async throws {
        let temporary = try await export()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(sessionName)
            try Data(contentsOf: temporary).write(to: destination, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try destination.setResourceValues(values)
            let logs = try list(directory: directory)
            for old in logs.dropFirst(20) { try FileManager.default.removeItem(at: old.url) }
        }.value
    }

    static func list(directory: URL = archiveDirectory) throws -> [LogFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            .compactMap { url in
                guard url.lastPathComponent.hasPrefix("Cassette-"), url.pathExtension == "txt" else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return LogFile(url: url, modifiedAt: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
            }
            .sorted { $0.modifiedAt == $1.modifiedAt ? $0.name > $1.name : $0.modifiedAt > $1.modifiedAt }
    }

    static func read(_ file: LogFile) async throws -> String {
        try await Task.detached(priority: .utility) {
            // Redact again when displaying archives written by an older app version.
            redact(try String(contentsOf: file.url, encoding: .utf8))
        }.value
    }

    static func export() async throws -> URL {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CassetteLogs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Cassette-\(UUID().uuidString).txt")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let formatter = ISO8601DateFormatter()
            var output = "Cassette \(version) (\(build))\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nExported: \(formatter.string(from: Date()))\nCurrent process, available logs from the last 24 hours.\nCassette diagnostics and system errors; newest entries retained within 5 MB.\n\n"
            var buffer = RecentLogBuffer(limit: 5 * 1024 * 1024 - 4096)
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: Date().addingTimeInterval(-86400)))
            for entry in entries {
                try Task.checkCancellation()
                guard let log = entry as? OSLogEntryLog else { continue }
                guard log.subsystem.hasPrefix("app.cassette") || log.subsystem.lowercased().contains("swiftsonic")
                        || log.subsystem == Bundle.main.bundleIdentifier
                        || log.level == .error || log.level == .fault else { continue }
                let line = "\(formatter.string(from: log.date)) [\(log.subsystem)/\(log.category)] \(redact(log.composedMessage))\n"
                buffer.append(line)
            }
            if buffer.truncated { output += "[Older or oversized entries omitted to keep the newest diagnostics]\n\n" }
            output += buffer.text
            try output.write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
    }

    static func redact(_ text: String) -> String {
        var output = text
        if let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\\"<>]+", options: .caseInsensitive) {
            for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
                guard let range = Range(match.range, in: output),
                      var url = URLComponents(string: String(output[range])) else { continue }
                url.user = nil; url.password = nil
                // Keep playback-quality diagnostics while removing arbitrary auth/query values.
                let safe: Set<String> = ["format", "maxbitrate", "codec", "audioformat", "static", "timestart"]
                url.queryItems = url.queryItems?.map {
                    URLQueryItem(name: $0.name, value: safe.contains($0.name.lowercased()) ? $0.value : "REDACTED")
                }
                if let sanitized = url.string { output.replaceSubrange(range, with: sanitized) }
            }
        }
        for pattern in [
            #"(?i)\b(?:Bearer|Basic)\s+[^\s\"',]+"#,
            #"(?im)\b(authorization|x-emby-token|x-mediabrowser-token|x-api-key)\s*[\"']?\s*[:=][^\r\n]+"#,
            #"(?i)(password|client_secret|access_token|api_key|clientSecret|secret|token)\s*[\"']?\s*[:=]\s*[\"']?[^\s\"',}]+"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "[REDACTED]")
            }
        }
        return output
    }
}
