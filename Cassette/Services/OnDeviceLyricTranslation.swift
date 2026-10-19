// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Bounded recovery around a model request, independent of model availability and UI state.
nonisolated enum OnDeviceLyricTranslation {
    static let maximumBatchCharacters = 600
    static let maximumBatchLines = 6

    enum ResponseError: Error { case invalidResponse, contextLimit }
    typealias Request = @MainActor ([String]) async throws -> [String]

    static func responseTokenLimit(inputTokens: Int, contextSize: Int, sourceUTF8Count: Int) throws -> Int {
        let available = contextSize - inputTokens - 128 // Session framing and generation overhead.
        let required = min(1_800, max(384, sourceUTF8Count * 2))
        guard available >= required else { throw ResponseError.contextLimit }
        return min(1_800, available)
    }

    /// Preserve every character; prefer word boundaries when splitting an unsynced long line.
    static func segments(_ text: String, limit: Int = maximumBatchCharacters) -> [String] {
        precondition(limit > 0)
        var remainder = text[...]
        var result: [String] = []
        while remainder.count > limit {
            let end = remainder.index(remainder.startIndex, offsetBy: limit)
            let halfway = remainder.index(remainder.startIndex, offsetBy: limit / 2)
            let boundary = remainder[halfway..<end].lastIndex(where: \.isWhitespace)
                .map { remainder.index(after: $0) } ?? end
            result.append(String(remainder[..<boundary]))
            remainder = remainder[boundary...]
        }
        if !remainder.isEmpty { result.append(String(remainder)) }
        return result
    }

    static func batches(_ sources: [String]) -> [[String]] {
        var result: [[String]] = []
        var batch: [String] = []
        var characters = 0
        for source in sources {
            if !batch.isEmpty && (batch.count >= maximumBatchLines || characters + source.count > maximumBatchCharacters) {
                result.append(batch)
                batch = []
                characters = 0
            }
            batch.append(source)
            characters += source.count
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }

    @MainActor static func translate(lines: [String], request: Request) async throws -> [String] {
        try Task.checkCancellation()
        let partsByLine = lines.map { line in
            segments(line.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        let sources = partsByLine.flatMap { $0 }.filter { seen.insert($0).inserted }
        var translated: [String: String] = [:]
        for batch in batches(sources) {
            let values = try await translateBatch(batch, retrySingle: true, request: request)
            for (source, value) in zip(batch, values) { translated[source] = value }
        }
        try Task.checkCancellation()
        return partsByLine.map { parts in parts.map { translated[$0] ?? "" }.joined(separator: " ") }
    }

    @MainActor private static func translateBatch(
        _ sources: [String], retrySingle: Bool, request: Request
    ) async throws -> [String] {
        try Task.checkCancellation()
        var failure = ResponseError.invalidResponse
        var values: [String] = []
        do {
            values = try await request(sources).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch let error as ResponseError {
            failure = error
        }
        // Cancellation, model availability, language support and refusals are never retried.
        try Task.checkCancellation()
        if values.count == sources.count {
            if values.allSatisfy({ !$0.isEmpty }) { return values }
            if sources.count > 1 {
                for index in values.indices where values[index].isEmpty {
                    values[index] = try await translateBatch([sources[index]], retrySingle: true, request: request)[0]
                }
                return values
            }
        }
        if sources.count > 1 {
            let middle = sources.count / 2
            let first = try await translateBatch(Array(sources[..<middle]), retrySingle: true, request: request)
            let last = try await translateBatch(Array(sources[middle...]), retrySingle: true, request: request)
            return first + last
        }
        if case .contextLimit = failure, let source = sources.first, source.count > 128 {
            let parts = segments(source, limit: source.count / 2)
            var result: [String] = []
            for part in parts {
                result += try await translateBatch([part], retrySingle: true, request: request)
            }
            return [result.joined(separator: " ")]
        }
        if retrySingle, case .invalidResponse = failure {
            return try await translateBatch(sources, retrySingle: false, request: request)
        }
        throw failure
    }
}
