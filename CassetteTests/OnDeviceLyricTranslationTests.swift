// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import FoundationModels
import Testing
@testable import Cassette

@Suite("On-device lyric response recovery") @MainActor
struct OnDeviceLyricTranslationTests {
    @Test func missingRowsRetrySmallerBatchesWithoutShiftingLyrics() async throws {
        var requests: [[String]] = []
        let result = try await OnDeviceLyricTranslation.translate(lines: ["one", "", "two", "one", "three"]) { sources in
            requests.append(sources)
            return sources.count > 1 ? ["잘못된 묶음"] : sources.map { "번역:\($0)" }
        }
        #expect(result == ["번역:one", "", "번역:two", "번역:one", "번역:three"])
        #expect(requests.filter { $0 == ["one"] }.count == 1)
        #expect(requests.count == 5)
    }

    @Test func onlyEmptyRowsAreRetried() async throws {
        var requests: [[String]] = []
        let result = try await OnDeviceLyricTranslation.translate(lines: ["one", "two", "three"]) { sources in
            requests.append(sources)
            return sources.count == 3 ? ["하나", " \n", "셋"] : ["둘"]
        }
        #expect(result == ["하나", "둘", "셋"])
        #expect(requests == [["one", "two", "three"], ["two"]])
    }

    @Test func malformedSingleLineHasABoundedRetry() async {
        var attempts = 0
        do {
            _ = try await OnDeviceLyricTranslation.translate(lines: ["line"]) { _ in
                attempts += 1
                return []
            }
            Issue.record("Incomplete model output was accepted")
        } catch OnDeviceLyricTranslation.ResponseError.invalidResponse {
            #expect(attempts == 2)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func malformedResponseErrorsRecoverInSmallerBatches() async throws {
        var attempts = 0
        let result = try await OnDeviceLyricTranslation.translate(lines: ["one", "two"]) { sources in
            attempts += 1
            if sources.count > 1 { throw OnDeviceLyricTranslation.ResponseError.invalidResponse }
            return sources.map { "번역:\($0)" }
        }
        #expect(result == ["번역:one", "번역:two"])
        #expect(attempts == 3)
    }

    @Test func irreducibleContextLimitDoesNotRetryTheSameRequest() async {
        var attempts = 0
        do {
            _ = try await OnDeviceLyricTranslation.translate(lines: ["short line"]) { _ in
                attempts += 1
                throw OnDeviceLyricTranslation.ResponseError.contextLimit
            }
            Issue.record("Context limit was ignored")
        } catch OnDeviceLyricTranslation.ResponseError.contextLimit {
            #expect(attempts == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func longUnicodeLineIsSplitWithoutLosingOrReorderingText() async throws {
        let line = String(repeating: "긴 가사 👨‍👩‍👧‍👦 한 줄입니다. ", count: 100)
        let parts = OnDeviceLyricTranslation.segments(line)
        #expect(parts.joined() == line)
        #expect(parts.allSatisfy { $0.count <= 600 })
        let result = try await OnDeviceLyricTranslation.translate(lines: [line, "", line]) { sources in
            #expect(sources.reduce(0) { $0 + $1.count } <= 600)
            return sources
        }
        #expect(result.count == 3)
        #expect(result[0] == line.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(result[1].isEmpty && result[2] == result[0])
    }

    @Test func contextOverflowSplitsEvenASingleLongLine() async throws {
        let source = String(repeating: "a", count: 600)
        var attempts = 0
        let result = try await OnDeviceLyricTranslation.translate(lines: [source]) { sources in
            attempts += 1
            if sources[0].count > 200 { throw OnDeviceLyricTranslation.ResponseError.contextLimit }
            return sources
        }
        #expect(result[0].replacingOccurrences(of: " ", with: "") == source)
        #expect(attempts == 7)
    }

    @Test func contextBudgetReservesOutputForALongKoreanPrompt() throws {
        #expect(try OnDeviceLyricTranslation.responseTokenLimit(
            inputTokens: 2_200, contextSize: 4_096, sourceUTF8Count: 600
        ) == 1_768)
        #expect(throws: OnDeviceLyricTranslation.ResponseError.self) {
            try OnDeviceLyricTranslation.responseTokenLimit(inputTokens: 3_400, contextSize: 4_096, sourceUTF8Count: 600)
        }
    }

    @Test func providerFailuresAndCancellationAreNotRetried() async {
        enum ProviderError: Error { case unavailable }
        var attempts = 0
        do {
            _ = try await OnDeviceLyricTranslation.translate(lines: ["one", "two"]) { _ in
                attempts += 1
                throw ProviderError.unavailable
            }
        } catch ProviderError.unavailable {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(attempts == 1)
        let task = Task {
            try await OnDeviceLyricTranslation.translate(lines: ["one", "two"]) { _ in
                attempts += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
        }
        do { _ = try await task.value; Issue.record("Cancellation was ignored") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(attempts == 2)
    }

    @Test func schemaRequiresExactlyTheInputLineCount() throws {
        guard #available(iOS 26, macOS 26, *) else { return }
        for count in [1, 3, 6] {
            let schema = try AppleIntelligenceLyricsTranslator.responseSchema(lineCount: count)
            let data = try JSONEncoder().encode(schema)
            let json = String(decoding: data, as: UTF8.self)
            #expect(json.contains("\"minItems\":\(count)"))
            #expect(json.contains("\"maxItems\":\(count)"))
        }
    }
}
